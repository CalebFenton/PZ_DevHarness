-- Development only, not published. bin/run-client.sh loads this mod with the mod under test and
-- its dev mod, and writes <cachedir>/Lua/PZHarness.txt: the mode (empty when playing by hand), the
-- selection (TESTS prefixes and exact "=<name>" names, or the mod's own for its modes), whether to
-- stay, whether the client joins a dedicated server (--mp), the console mark of the mode, the
-- tests' console tag, and for tests the leak check (LEAKS), the order (ORDER) and the rounds
-- (REPEAT).
--
-- The dev mod calls PZHarness.register (see docs/adopting.md). In a mode, the mod's debug scenario then
-- starts from the main menu (with -debug and DebugScenario.ForceLaunch=true in debug-options.ini);
-- once the world around the character has loaded, the runner runs the mod's tests ("test") or the
-- mod's handler for the mode, prints "<mark> DONE" and quits. With --test --stay the game stays
-- open and reruns the tests on request instead. run-client.sh reads those lines from console.txt.
--
-- With --mp the client instead joins the server run-client.sh started, as its admin, makes a
-- default character, takes it to the scenario's start and runs the scenario's onStart there; the
-- tests then run the same way.

require "ISUI/ISUIElement"
require "PZHarness/ServerCalls"
require "PZHarness/Fixtures"
require "PZHarness/Leaks"

PZHarness = PZHarness or {}

-- A run starts once one square in every chunk this many squares around the character has loaded,
-- or after SETTLE_MAX_TICKS ticks.
local LOADED_RADIUS = 40
local SETTLE_MAX_TICKS = 600
-- How long a test waits for the character's square to load after the last test took it far away.
local SQUARE_WAIT_MS = 10000
-- A test still busy after this many real seconds fails with what it was waiting on, its queue is
-- cleared and its undos run, so one hung step can't stall the run. A spec's `timeoutSeconds`
-- raises it for a test that is slow on purpose. The slowest tests take under 10 seconds.
local TEST_TIMEOUT_SECONDS = 30
-- How many of the slowest tests the run's summary names.
local SLOWEST_COUNT = 10
-- The leak check looks this much further than the test library places fixtures (its
-- SEARCH_RADIUS), unless the dev mod's `leakRadius` setting says otherwise.
local LEAK_MARGIN = 2
-- At most this many LEAK and DESYNC lines per test, and DIRTY lines per run; a count of the rest
-- follows.
local LEAK_LINES_SHOWN = 10
-- With --stay, run-client.sh writes this file in <cachedir>/Lua to rerun the tests; the game looks
-- for it every REQUEST_POLL_TICKS ticks and quits after STAY_IDLE_MS without one. Starting a
-- multiplayer game again costs about a minute, so a kept game waits through a long pause.
local REQUEST_FILE = "PZHarnessRerun.txt"
local REQUEST_POLL_TICKS = 15
local STAY_IDLE_MS = 30 * 60 * 1000
-- While --stay waits, the game draws only this many frames a second, so it doesn't keep a core busy.
local IDLE_FPS = 24
-- The highest uiRenderFPS the option takes (Core.optionUiRenderFps).
local FAST_UI_FPS = 120
-- With --mp, run-client.sh writes this file in <cachedir>/Lua once the server has started; the
-- client waits at the main menu until then, looking for it every CONNECT_POLL_TICKS ticks.
local CONNECT_FILE = "PZHarnessConnect.txt"
local CONNECT_POLL_TICKS = 15

-- The key=value lines of <cachedir>/Lua/<name>, or nil without the file.
local function readKeys(name)
    local reader = getFileReader(name, false)
    if not reader then
        return nil
    end
    local keys = {}
    local line = reader:readLine()
    while line do
        local key, value = string.match(line, "^(%w+)=(.*)$")
        if key then
            keys[key] = value
        end
        line = reader:readLine()
    end
    reader:close()
    return keys
end

-- The run run-client.sh asked for. Without the file, as in a game the script didn't start, there
-- is no mode and the tests print under a generic tag.
local function readRun()
    local run = { mode = "", selection = "", stay = false, mp = false, mark = "PZHarness", tag = "PZHarness" }
    for key, value in pairs(readKeys("PZHarness.txt") or {}) do
        if key == "stay" or key == "mp" then
            run[key] = value ~= ""
        else
            run[key] = value
        end
    end
    return run
end

PZHarness.run = readRun()
local run = PZHarness.run

-- What the dev mod registered; see PZHarness.register.
PZHarness.config = PZHarness.config or { prefix = "", modes = {}, tests = {} }

local function startsWith(text, prefix)
    return string.sub(text, 1, #prefix) == prefix
end
PZHarness.startsWith = startsWith

--- What every per-test result line (PASS, FAIL, SKIP) ends with: the test's wall time.
function PZHarness.tookSuffix(seconds)
    return string.format(" (%.2f s)", seconds)
end

-- Name prefixes from TESTS, or exact names written "=<name>" (--failed); empty runs every test of
-- the mod.
local filters = {}

local function setFilters(tests)
    filters = {}
    for prefix in string.gmatch(tests or "", "[^,%s]+") do
        table.insert(filters, prefix)
    end
end

local function matchesFilter(name, filter)
    local exact = string.match(filter, "^=(.*)$")
    return exact == name or (not exact and startsWith(name, filter))
end

local function selected(name)
    if not startsWith(name, PZHarness.config.prefix) then
        return false
    end
    if #filters == 0 then
        return true
    end
    for _, filter in ipairs(filters) do
        if matchesFilter(name, filter) then
            return true
        end
    end
    return false
end

-- Why the test `entry` doesn't run in this game, or nil: the opt-out of its spec (TestLib's
-- spOnly and mpOnly) for the other mode.
local function skipReason(entry)
    if isClient() then
        return entry.spOnly and "single player only: " .. entry.spOnly
    end
    return entry.mpOnly and "multiplayer only: " .. entry.mpOnly
end

-- The selected tests to run, and those skipped in this mode as "<name>: <why>"; both sorted. Then
-- the selection's entries that name no test at all, such as a typo or a TEST_MAP entry for a test
-- that has since been renamed.
local function testNames()
    local result, skipped, used = {}, {}, {}
    for name, entry in pairs(TimedActionTests.getTests()) do
        if selected(name) then
            local reason = skipReason(entry)
            table.insert(reason and skipped or result, reason and name .. ": " .. reason or name)
            for _, filter in ipairs(filters) do
                used[filter] = used[filter] or matchesFilter(name, filter)
            end
        end
    end
    local unmatched = {}
    for _, filter in ipairs(filters) do
        if not used[filter] then
            table.insert(unmatched, filter)
        end
    end
    table.sort(result)
    table.sort(skipped)
    return result, skipped, unmatched
end

-- Random numbers from 1 to n that the same seed repeats (Park and Miller's generator: the products
-- stay exact in a double), since ZombRand can't be seeded.
local function seededRandom(seed)
    local value = seed % 2147483646 + 1
    return function(n)
        value = (value * 16807) % 2147483647
        return value % n + 1
    end
end

-- `names` in the run's order (ORDER: "reverse", or "shuffle:<seed>"), `rounds` times over
-- (REPEAT), each round of a shuffle in a new order.
local function orderedRounds(names, order, rounds)
    local seed = tonumber(string.match(order, "^shuffle:(%d+)$"))
    local random = seed and seededRandom(seed)
    local result = {}
    for _ = 1, rounds do
        local round = {}
        for i, name in ipairs(names) do
            round[order == "reverse" and #names + 1 - i or i] = name
        end
        if random then
            for i = #round, 2, -1 do
                local j = random(i)
                round[i], round[j] = round[j], round[i]
            end
        end
        for _, name in ipairs(round) do
            table.insert(result, name)
        end
    end
    return result
end

-- The inventory windows hold the containers that crafts and the craft menu take their inputs from
-- (ISInventoryPaneContextMenu.getContainers), and catch up with a change only when the UI next
-- draws: until then they keep a bag the reset just took away, such as the key ring a multiplayer
-- character starts with, whose container the client can't name to the server
-- ("Unable to resolve container location"), so the action never reaches it.
local function refreshInventoryWindows()
    for _, page in ipairs({ getPlayerInventory(0), getPlayerLoot(0) }) do
        if page then
            page.inventoryPane.inventoryPage:refreshBackpacks()
        end
    end
end

-- What the last run in this game left behind, as "<test>: <what>", which a kept game's next run
-- reports first: it is still in the world that run starts from.
local leftBehind = {}

-- Prints up to LEAK_LINES_SHOWN of `lines` as "<tag> <kind> <prefix><line>", then how many more.
local function printCapped(kind, prefix, lines)
    for i, line in ipairs(lines) do
        if i > LEAK_LINES_SHOWN then
            print(string.format("%s %s %sand %d more", run.tag, kind, prefix, #lines - LEAK_LINES_SHOWN))
            return
        end
        print(run.tag .. " " .. kind .. " " .. prefix .. line)
    end
end

local function countVerdict(state, name, passed)
    local tally = state.tally[name] or { passed = 0, failed = 0 }
    state.tally[name] = tally
    if passed then
        state.passed, tally.passed = state.passed + 1, tally.passed + 1
    else
        state.failed, tally.failed = state.failed + 1, tally.failed + 1
    end
end

-- Prints the verdict of the test that just ended, once the leak check after it is done: its LEAK
-- and DESYNC lines first, which with LEAKS=fail also fail it.
local function settleVerdict(state, found)
    local verdict = state.verdict
    state.verdict = nil
    if not verdict then
        return
    end
    local failures = verdict.failures
    local findings = {}
    for _, line in ipairs(found and found.leaks or {}) do
        table.insert(findings, { kind = "LEAK", line = line })
    end
    for _, line in ipairs(found and found.desyncs or {}) do
        table.insert(findings, { kind = "DESYNC", line = line })
    end
    for i, finding in ipairs(findings) do
        if i > LEAK_LINES_SHOWN then
            local rest = #findings - LEAK_LINES_SHOWN
            print(string.format("%s LEAK %s: and %d more", run.tag, verdict.name, rest))
            if state.leaks == "fail" then
                table.insert(failures, rest .. " more leaks and desyncs")
            end
            break
        end
        print(run.tag .. " " .. finding.kind .. " " .. verdict.name .. ": " .. finding.line)
        table.insert(leftBehind, verdict.name .. ": " .. finding.line)
        if state.leaks == "fail" then
            table.insert(failures, (finding.kind == "LEAK" and "left behind " or "client and server differ at ") .. finding.line)
        end
    end
    PZHarness.Test.printVerdict(verdict.name, failures, verdict.seconds)
    countVerdict(state, verdict.name, #failures == 0)
end

-- The current test is done once its action queue is empty, or stopped once it overruns its limit
-- (TEST_TIMEOUT_SECONDS or its spec's timeoutSeconds): its queue cleared, and validate() fails it
-- with what it was waiting on. Then validate() runs, and its verdict waits for the leak check
-- (settleVerdict); the test's wall time and its time waiting on the server go to the run's
-- summary, and the cheat and the character go back to where the test started.
local function finishCurrentTest(state)
    local current, player = state.current, state.player
    local queue = ISTimedActionQueue.getTimedActionQueue(player).queue
    if queue[1] then
        local limit = current.timeoutSeconds or TEST_TIMEOUT_SECONDS
        if getTimestampMs() - state.testStartMs < limit * 1000 then
            return
        end
        current.timedOut = string.format("still running after %d s, waiting on %s", limit,
            PZHarness.Test.describeAction(queue[1]))
        ISTimedActionQueue.clear(player)
    end
    local passed = not current.validate or current:validate()
    state.current = nil
    state.doneMs = getTimestampMs()
    -- TestLib's validate leaves its failures and the test's time; a test registered some other way
    -- has only its verdict.
    local seconds = current.seconds or (state.doneMs - state.testStartMs) / 1000
    state.verdict = { name = state.name, seconds = seconds,
        failures = current.failures or (passed and {} or { "validate failed" }) }
    table.insert(state.times, {
        name = state.name,
        seconds = seconds,
        serverSeconds = (PZHarness.ServerCalls.waitedMs() - state.testServerMs) / 1000,
    })
    ISBuildMenu.cheat = state.wasCheat
    PZHarness.Fixtures.teleportToMiddle(player, state.start.x, state.start.y, state.start.z)
end

-- Whether the leak check may come, then the next test or the end of the run: the character's
-- square has loaded again after a test that went far, or SQUARE_WAIT_MS have passed; the server
-- has answered what the last test sent it, its undos above all, so a test never meets what the
-- one before built; and, in multiplayer, the server has reset its copy of the character, which the
-- first call asks for.
local function readyForNextTest(state)
    if not state.player:getCurrentSquare() and getTimestampMs() - state.doneMs < SQUARE_WAIT_MS then
        return false
    end
    if PZHarness.ServerCalls.busy() then
        return false
    end
    local nextIndex = state.index + 1
    if isClient() and state.resetFor ~= nextIndex and (state.names[nextIndex] or state.leaks ~= "off") then
        state.resetFor = nextIndex
        PZHarness.ServerCalls.callOutsideTest("PZHarness.reset", {})
        return false
    end
    return true
end

-- Between two tests, and after the last: the runner's reset of the character, then the leak check
-- (PZHarness/Leaks.lua), which compares the world with how it was before the test that just ended,
-- then that test's verdict. Returns true once all of it is done. A check whose square never loaded
-- finds nothing and starts the baselines over.
local function checkBetweenTests(state)
    if state.checkedFor == state.index then
        return true
    end
    if not state.check then
        -- Before the snapshot, so what the reset takes away doesn't count as left behind.
        PZHarness.Fixtures.resetCharacter(state.player)
        refreshInventoryWindows()
        if state.leaks == "off" then
            settleVerdict(state, nil)
            state.checkedFor = state.index
            return true
        end
        state.checkStartMs = getTimestampMs()
        state.check = PZHarness.Leaks.start(state.player, state.leakRadius, state.leakLevels, state.leakIgnore)
    end
    local found = state.check()
    if not found then
        return false
    end
    state.check = nil
    state.leakMs = state.leakMs + getTimestampMs() - state.checkStartMs
    if found.waitedFull then
        state.leakWaitedFull = state.leakWaitedFull + 1
    end
    settleVerdict(state, found)
    state.checkedFor = state.index
    return true
end

-- Starts test `name` from the character's square, which the leak check's reset has just reset. If
-- that square still hasn't loaded since the last test took the character far away, the test fails
-- without running, since nothing could bring the character back to where it started, and the next
-- one waits again. The time since the last test ended counts as between tests in the run's summary.
local function startNextTest(state, name)
    local player = state.player
    state.gapMs = state.gapMs + getTimestampMs() - state.doneMs
    print("TEST: " .. name)
    local here = player:getCurrentSquare()
    if not here then
        print(string.format("%s FAIL %s: the character's square was still unloaded %d s after the last test%s",
            run.tag, name, SQUARE_WAIT_MS / 1000, PZHarness.tookSuffix(0)))
        countVerdict(state, name, false)
        state.doneMs = getTimestampMs()
        return
    end
    state.name = name
    state.current = state.tests[name]
    state.start = { x = here:getX(), y = here:getY(), z = here:getZ() }
    player:Say(name)
    state.wasCheat = ISBuildMenu.cheat
    ISBuildMenu.cheat = false
    state.testStartMs = getTimestampMs()
    state.testServerMs = PZHarness.ServerCalls.waitedMs()
    state.current:run()
end

-- Prints the SLOWEST_COUNT slowest tests, then where the run's time went: in the tests, between
-- them (square loads, the server's resets and undos the runner waits for, the leak checks), and in
-- multiplayer how much of both had a server answer outstanding.
local function printSlowest(state)
    local times = state.times
    table.sort(times, function(a, b)
        if a.seconds ~= b.seconds then
            return a.seconds > b.seconds
        end
        return a.name < b.name
    end)
    local inTests = 0
    for i, entry in ipairs(times) do
        inTests = inTests + entry.seconds
        if i <= SLOWEST_COUNT then
            print(string.format("%s SLOWEST %.2f s %s%s", run.tag, entry.seconds, entry.name,
                isClient() and string.format(" (server %.2f s)", entry.serverSeconds) or ""))
        end
    end
    local summary = string.format("%s SLOWEST %.1f s in tests, %.1f s between them (%.1f s of it checking for leaks)",
        run.tag, inTests, state.gapMs / 1000, state.leakMs / 1000)
    if isClient() then
        summary = summary .. string.format(", %.1f s of it all waiting on the server; %d leak checks waited the full time for this client to catch up",
            (PZHarness.ServerCalls.waitedMs() - state.serverStartMs) / 1000, state.leakWaitedFull)
    end
    print(summary)
end

-- With REPEAT, how often each test passed and failed, the most failed first.
local function printTally(state)
    local names = {}
    for name in pairs(state.tally) do
        table.insert(names, name)
    end
    table.sort(names, function(a, b)
        local failedA, failedB = state.tally[a].failed, state.tally[b].failed
        if failedA ~= failedB then
            return failedA > failedB
        end
        return a < b
    end)
    for _, name in ipairs(names) do
        local tally = state.tally[name]
        print(string.format("%s REPEAT %s passed=%d failed=%d", run.tag, name, tally.passed, tally.failed))
    end
end

-- Prints the skipped tests, the counts of a repeated run, the slowest tests, the time the run took
-- and its verdict, counting the failures that came after their tests' verdicts, then calls
-- onDone().
local function finishRun(state)
    PZHarness.runnerOwnsVerdicts = false
    state.gapMs = state.gapMs + getTimestampMs() - state.doneMs
    local failed = state.failed + PZHarness.ServerCalls.lateFailures - state.lateFailures
    for _, skip in ipairs(state.skipped) do
        print(run.tag .. " SKIP " .. skip .. PZHarness.tookSuffix(0))
    end
    if state.rounds > 1 then
        printTally(state)
    end
    printSlowest(state)
    local seconds = (getTimestampMs() - state.startedMs) / 1000
    print(string.format("%s TIME %.1f s, %d frames (%.0f a second)", run.tag, seconds, state.ticks,
        state.ticks / math.max(seconds, 0.001)))
    print(run.tag .. " DONE passed=" .. state.passed .. " failed=" .. failed .. " skipped=" .. #state.skipped)
    state.onDone()
end

-- The leak check's mode (LEAKS: "fail", "warn" or "off"), its radius, its z levels, and the
-- patterns of the objects it leaves out: the built-in ones and the dev mod's `leakIgnore`.
local function leakSettings()
    local mode = run.leaks ~= nil and run.leaks ~= "" and run.leaks or "fail"
    local tests = PZHarness.config.tests
    local ignore = {}
    for _, list in ipairs({ PZHarness.Snapshot.DEFAULT_IGNORE, tests.leakIgnore or {} }) do
        for _, pattern in ipairs(list) do
            table.insert(ignore, pattern)
        end
    end
    return mode, tests.leakRadius or PZHarness.Test.SEARCH_RADIUS + LEAK_MARGIN, tests.leakLevels, ignore
end

-- What the last run in this game left behind, before this one starts on top of it.
local function printLeftBehind()
    if #leftBehind > 0 then
        printCapped("DIRTY", "", leftBehind)
        leftBehind = {}
    end
end

-- Runs the selected tests one after another with the resets of the debug menu's runner (RunTest
-- and OnTick in vanilla Tests/TimedActionsTests.lua, whose locals Lua can't reach): before each
-- test full health, an empty inventory, nothing worn or held, the inventory windows caught up with
-- that, ISBuildMenu.cheat off and the test's name said aloud; validate() once the action queue is
-- empty; then the cheat back and the character back in the middle of the square the test started
-- on. Vanilla pauses a second after every test so you can read the result; here the next test
-- starts on the next tick, or once readyForNextTest says so and the leak check after the last
-- test is done (checkBetweenTests). In multiplayer the server's copy of the character gets the
-- same reset first (PZHarness.Fixtures.resetCharacter). The run's ORDER, REPEAT and LEAKS come
-- from `run` (PZHarness.txt, or a --stay request). Calls onDone() at the end.
local function runTests(onDone)
    local names, skipped, unmatched = testNames()
    local rounds = math.max(1, tonumber(run.rounds) or 1)
    local order = run.order or ""
    local leaks, leakRadius, leakLevels, leakIgnore = leakSettings()
    printLeftBehind()
    names = orderedRounds(names, order, rounds)
    print(run.tag .. " START " .. #names)
    if order ~= "" then
        print(run.tag .. " ORDER " .. order)
    end
    if rounds > 1 then
        print(run.tag .. " REPEAT " .. rounds .. " rounds")
    end
    print(run.tag .. " LEAKS " .. leaks .. (leaks ~= "off" and ", " .. leakRadius .. " squares around the character" or ""))
    for _, filter in ipairs(unmatched) do
        print(run.tag .. " FAIL " .. filter .. ": the selection names no test")
    end
    PZHarness.Leaks.reset()
    PZHarness.runnerOwnsVerdicts = true
    local startedMs = getTimestampMs()
    -- `start` holds where the current test started, as numbers: the square object itself goes back
    -- to the pool when a test takes the character far enough for its chunk to unload, and comes
    -- back as some other square (IsoGridSquare.discard, getNew), so teleporting to its coordinates
    -- then lands somewhere else entirely.
    local state = {
        names = names, skipped = skipped, tests = TimedActionTests.getTests(), onDone = onDone,
        rounds = rounds, leaks = leaks, leakRadius = leakRadius, leakLevels = leakLevels, leakIgnore = leakIgnore,
        passed = 0, failed = #unmatched, index = 0, ticks = 0, startedMs = startedMs, doneMs = startedMs,
        lateFailures = PZHarness.ServerCalls.lateFailures,
        -- For the summary: each test's { name, seconds, serverSeconds }, the time between tests and
        -- the part of it the leak checks took, the checks that waited the full time for this
        -- client to catch up with the server, the server waits so far, which a kept game's
        -- earlier runs add to, and each test's passes and failures over the rounds.
        times = {}, gapMs = 0, leakMs = 0, leakWaitedFull = 0, serverStartMs = PZHarness.ServerCalls.waitedMs(), tally = {},
        current = nil, name = nil, player = nil, start = nil, wasCheat = nil, resetFor = nil,
        testStartMs = nil, testServerMs = nil,
        -- The verdict waiting for the leak check, the check under way, and the test index it ran
        -- after.
        verdict = nil, check = nil, checkStartMs = nil, checkedFor = nil,
    }
    local function onTick()
        state.ticks = state.ticks + 1
        if state.current then
            finishCurrentTest(state)
            return
        end
        state.player = getSpecificPlayer(0)
        if not readyForNextTest(state) or not checkBetweenTests(state) then
            return
        end
        state.index = state.index + 1
        local name = state.names[state.index]
        if name then
            startNextTest(state, name)
        else
            Events.OnTick.Remove(onTick)
            finishRun(state)
        end
    end
    Events.OnTick.Add(onTick)
end

-- The request run-client.sh writes to REQUEST_FILE: an id, the selection (TESTS prefixes and
-- "=<name>" names), then "option <key>=<value>" lines for the run's settings (leaks, order,
-- rounds), then the Lua files to run again, in the order the mod listed them: this game's paths,
-- then, with --mp, "server " and the server's paths of those it loads too. Nil if there is none.
local function readRequest()
    local reader = getFileReader(REQUEST_FILE, false)
    if not reader then
        return nil
    end
    local request = { id = reader:readLine(), tests = reader:readLine(), options = {}, files = {}, serverFiles = {} }
    local line = reader:readLine()
    while line do
        local key, value = string.match(line, "^option (%w+)=(.*)$")
        local serverFile = string.match(line, "^server (.*)$")
        if key then
            request.options[key] = value
        else
            table.insert(serverFile and request.serverFiles or request.files, serverFile or line)
        end
        line = reader:readLine()
    end
    reader:close()
    return request
end

-- What the kept game shows on screen and prints while it waits for a request, so whoever watches
-- the window can tell an idle game from a stuck one.
local IDLE_TEXT = run.tag .. " IDLE waiting for the next --stay run (quits after " .. STAY_IDLE_MS / 60000 .. " minutes)"

local IdleNote = ISUIElement:derive("PZHarnessIdleNote")

function IdleNote:render()
    self:drawText(IDLE_TEXT, 0, 0, 1, 1, 0.4, 1, UIFont.Large)
end

-- Runs the tests again for every new request until STAY_IDLE_MS pass without one. reloadLuaFile
-- runs a file again but ignores its Events.*.Add calls (LuaCompiler.rewriteEvents), which suits
-- test files: they only register tests, or server handlers. Every test of the mod is unregistered
-- first, so a test that was renamed or deleted doesn't run again. In multiplayer the server
-- reloads its files first and marks the run in its log.
local function serveReruns()
    local performance = getPerformance()
    local fps, uncapped = performance:getFramerate(), performance:isFramerateUncapped()
    local note = IdleNote:new(40, 40, getCore():getScreenWidth() - 80, 40)
    note:initialise()
    local handled
    local waitingSince, ticks = getTimestampMs(), 0
    local onTick
    local function idle()
        performance:setFramerateUncapped(false)
        performance:setFramerate(IDLE_FPS)
        print(IDLE_TEXT)
        note:addToUIManager()
        waitingSince = getTimestampMs()
        Events.OnTick.Add(onTick)
    end
    onTick = function()
        ticks = ticks + 1
        if ticks % REQUEST_POLL_TICKS ~= 0 then
            return
        end
        if getTimestampMs() - waitingSince > STAY_IDLE_MS then
            Events.OnTick.Remove(onTick)
            print(run.tag .. " STAY ends: no request for " .. STAY_IDLE_MS / 60000 .. " minutes")
            getCore():quitToDesktop()
            return
        end
        local request = readRequest()
        if not request or not request.id or request.id == handled then
            return
        end
        handled = request.id
        Events.OnTick.Remove(onTick)
        note:removeFromUIManager()
        performance:setFramerate(fps)
        performance:setFramerateUncapped(uncapped)
        print(run.tag .. " RUN " .. request.id)
        local function rerun()
            local tests = TimedActionTests.getTests()
            local registered = {}
            for name in pairs(tests) do
                if startsWith(name, PZHarness.config.prefix) then
                    table.insert(registered, name)
                end
            end
            for _, name in ipairs(registered) do
                tests[name] = nil
            end
            for _, file in ipairs(request.files) do
                reloadLuaFile(file)
            end
            setFilters(request.tests)
            for key, value in pairs(request.options) do
                run[key] = value
            end
            runTests(idle)
        end
        if not isClient() then
            rerun()
            return
        end
        -- A failure is in the server's log as SERVER FAIL, which fails the run.
        PZHarness.ServerCalls.send("reload", { run = request.id, files = request.serverFiles }, rerun)
    end
    idle()
end

local function quit()
    getCore():quitToDesktop()
end

-- The player's uiRenderFPS while fastUI holds. done() puts it back before the game quits, which
-- saves the options, so options.ini never keeps the mode's rate.
local savedUIFps

-- What a mode handler calls when it is done.
local function done()
    if savedUIFps then
        getCore():setOptionUIRenderFPS(savedUIFps)
        savedUIFps = nil
    end
    print(run.mark .. " DONE")
    quit()
end

-- A clear, still day at once: no cloud, fog or rain however the weather turns during the run.
-- Stopping the weather alone leaves its fog to fade out over seconds; the admin values hold until
-- switched off.
local function clearWeather()
    local climate = getClimateManager()
    climate:stopWeatherAndThunder()
    for _, id in ipairs({ ClimateManager.FLOAT_CLOUD_INTENSITY, ClimateManager.FLOAT_FOG_INTENSITY,
        ClimateManager.FLOAT_PRECIPITATION_INTENSITY }) do
        local float = climate:getClimateFloat(id)
        float:setEnableAdmin(true)
        float:setAdminValue(0)
    end
end

-- The UI draws at its own rate (Core.StartFrameUI) and the frames in between show its last
-- drawing, so a mode that waits for the UI to draw waits less at the highest rate.
local function fastUI()
    savedUIFps = getCore():getOptionUIRenderFPS()
    getCore():setOptionUIRenderFPS(FAST_UI_FPS)
end

local function worldLoaded()
    local square = getSpecificPlayer(0):getCurrentSquare()
    if not square then
        return false
    end
    local cell, x, y = getCell(), square:getX(), square:getY()
    for dx = -LOADED_RADIUS, LOADED_RADIUS, 8 do
        for dy = -LOADED_RADIUS, LOADED_RADIUS, 8 do
            if not cell:getGridSquare(x + dx, y + dy, 0) then
                return false
            end
        end
    end
    return true
end

-- Runs `start` once the world around the character has loaded.
local function afterSettling(start)
    local ticks = 0
    local function onTick()
        ticks = ticks + 1
        if worldLoaded() or ticks >= SETTLE_MAX_TICKS then
            Events.OnTick.Remove(onTick)
            print("PZHarness: starting after " .. ticks .. " ticks")
            start()
        end
    end
    Events.OnTick.Add(onTick)
end

local function startMode()
    if run.mode == "test" then
        setFilters(run.selection)
        runTests(run.stay and serveReruns or quit)
        return
    end
    local mode = PZHarness.config.modes[run.mode]
    if not mode then
        print("PZHarness: the dev mod registered no mode " .. run.mode)
        quit()
        return
    end
    if mode.clearWeather then
        clearWeather()
    end
    if mode.fastUI then
        fastUI()
    end
    mode.run(run.selection, done)
end

-- Multiplayer (--mp) -----------------------------------------------------------------------------

-- How long the character may take to reach the scenario's start, whose chunks the server sends.
local START_WAIT_MS = 30000
-- How long the client may take, after the server's answers, to show the onStart perk levels again.
local SETUP_SYNC_MS = 5000

-- Joins the server once run-client.sh says it has started, with the call the server list's
-- Connect button makes. The client and the server boot at the same time, which saves the
-- client's boot from a run; connecting before the server listens would only fail.
local function connectWhenServerUp()
    -- Joining resets Lua (Core.ResetLua), which fires OnMainMenuEnter again in a client that is
    -- already joining; isClient() holds from then on.
    if isClient() then
        return
    end
    local ticks = 0
    local function poll()
        ticks = ticks + 1
        local server = ticks % CONNECT_POLL_TICKS == 0 and readKeys(CONNECT_FILE)
        if not server then
            return
        end
        Events.OnFETick.Remove(poll)
        print("PZHarness: joining " .. server.host .. ":" .. server.port .. " as " .. server.user)
        ConnectToServer.instance:connect(MainScreen.instance.bottomPanel, "", server.user, server.password,
            server.host, "", server.port, "", false, true, 1)
    end
    Events.OnFETick.Add(poll)
end

-- After vanilla's OnConnected, which shows a new character the spawn region list or character
-- creation: the default unemployed survivor in the default spawn region, as those screens would
-- make. CharacterCreationProfession.initWorld places it on OnInitWorld.
local function skipCharacterCreation()
    if checkSavePlayerExists() then
        return
    end
    for _, screen in pairs({ MapSpawnSelect.instance, WorldSelect.instance, MainScreen.instance.charCreationProfession }) do
        screen:setVisible(false)
    end
    MainScreen.instance.desc = SurvivorFactory.CreateSurvivor(SurvivorType.Neutral, false)
    MapSpawnSelect.instance:useDefaultSpawnRegion()
    GameWindow.doRenderEvent(false)
    forceChangeState(LoadingQueueState.new())
end

local function connectFailed(message, detail)
    print("PZHarness: joining the server failed: " .. tostring(message) .. " " .. tostring(detail or ""))
    quit()
end

-- Whether every perk of the character is at its level in `levels` (Fixtures.perkLevels).
local function hasPerkLevels(player, levels)
    for id, level in pairs(levels) do
        local perk = Perks.FromString(id)
        if perk and perk ~= Perks.MAX and player:getPerkLevel(perk) ~= level then
            return false
        end
    end
    return true
end

-- Copies the perk levels and known recipes onStart gave this client's character to the server's
-- copy, which crafts and actions check, and calls `start` once the server has them and this
-- client shows them. The server replaces this client's perk list with its own copy's every second
-- (NetworkPlayerManager, PlayerXpPacket), and one it sent before it had the levels can land after
-- its answer, so the first test would find the skills too low: the wait holds until a sync after
-- the answers has rebuilt the list (new PerkInfo objects) with the levels, at most SETUP_SYNC_MS.
-- Recipes the server sends are only added (SyncPlayerFieldsPacket), so they can't go back.
local function copySetupToServer(start)
    local player = getSpecificPlayer(0)
    local levels = PZHarness.Fixtures.perkLevels(player)
    PZHarness.ServerCalls.callOutsideTest("PZHarness.setPerkLevels", { levels = levels })
    PZHarness.ServerCalls.callOutsideTest("PZHarness.learnRecipes", { names = PZHarness.Fixtures.knownRecipes(player) })
    local perkList = player:getPerkList()
    local answeredMs, before
    local function onTick()
        if PZHarness.ServerCalls.busy() then
            return
        end
        if not answeredMs then
            answeredMs = getTimestampMs()
            before = not perkList:isEmpty() and perkList:get(0) or nil
        end
        local synced = before == nil or perkList:isEmpty() or perkList:get(0) ~= before
        if not (synced and hasPerkLevels(player, levels)) then
            if getTimestampMs() - answeredMs < SETUP_SYNC_MS then
                return
            end
            print(run.tag .. " FAIL PZHarness.setPerkLevels: this client never showed the onStart perk levels again")
            PZHarness.ServerCalls.lateFailures = PZHarness.ServerCalls.lateFailures + 1
        end
        Events.OnTick.Remove(onTick)
        start()
    end
    Events.OnTick.Add(onTick)
end

-- The server places a new character on a point of a spawn region (CreatePlayerPacket), so the
-- character goes to the scenario's start, where single player starts, as soon as it is in the
-- game. Then, once the world around it has loaded as it has when single player starts the
-- scenario: the scenario's onStart and the mod's, then the run once the server's copy has the
-- perks and recipes they gave (copySetupToServer). The test library's helpers they call
-- (T.learnRecipes, T.placeWorkTable) reach the server themselves; items needn't, since every test
-- starts with an empty inventory. Anything else goes through the mod's own server handlers.
local function startMultiplayer()
    local scenario = debugScenarios[PZHarness.config.scenario] or {}
    local loc = scenario.startLoc
    local sinceMs, teleported = getTimestampMs(), false
    local function onTick()
        local player = getSpecificPlayer(0)
        local here = player:getCurrentSquare()
        if loc and not (here and here:getX() == loc.x and here:getY() == loc.y and here:getZ() == loc.z) then
            if not teleported then
                PZHarness.Fixtures.teleportToMiddle(player, loc.x, loc.y, loc.z)
                teleported = true
            end
            if getTimestampMs() - sinceMs < START_WAIT_MS then
                return
            end
            print("PZHarness: the character didn't reach the scenario's start; the tests run where it is")
        end
        Events.OnTick.Remove(onTick)
        afterSettling(function()
            if scenario.onStart then
                scenario.onStart()
            end
            if PZHarness.config.onStart then
                PZHarness.config.onStart(run.mode)
            end
            copySetupToServer(startMode)
        end)
    end
    Events.OnTick.Add(onTick)
end

if run.mp then
    Events.OnMainMenuEnter.Add(connectWhenServerUp)
    Events.OnConnected.Add(skipCharacterCreation)
    Events.OnConnectFailed.Add(connectFailed)
    Events.OnGameStart.Add(startMultiplayer)
end

-- Every world started from the mod's scenario, by hand too, records the three mods, which
-- DebugScenarios doesn't do for the new save (see MainScreen.resetLuaIfNeeded), and has no
-- zombies, so nothing attacks the character. A --test world is quiet too: the options
-- run-client.sh lists in `quiet` (QUIET_WORLD in lib/harness.sh). All of it goes in before the
-- new world is made, and the scenario's own setSandbox after it, so the mod's settings win.
local function wrapSetSandbox(scenario, quiet)
    local originalSetSandbox = scenario.setSandbox
    scenario.setSandbox = function()
        ActiveMods.getById("currentGame"):copyFrom(ActiveMods.getById("default"))
        SandboxVars.Zombies = 6 -- none
        for key, value in string.gmatch(quiet, "([%w_]+)=([^,]+)") do
            if value == "true" or value == "false" then
                SandboxVars[key] = value == "true"
            else
                SandboxVars[key] = tonumber(value) or value
            end
        end
        if originalSetSandbox then
            originalSetSandbox()
        end
    end
end

--- Called once by the dev mod, at load. `config`:
--- - `scenario`: the key of the mod's scenario in `debugScenarios`, which every mode starts. Its
---   world gets the active mods and no zombies from the harness.
--- - `prefix`: the name prefix of the mod's tests in TimedActionTests; --test runs those.
--- - `modes`: the mod's other modes by name, each `{ run = function(selection, done), uncapped,
---   clearWeather, fastUI }`. `run` is called once the world has loaded, with the selection
---   run-client.sh passed, and calls `done()` when it has finished. `uncapped` draws as many
---   frames as the machine can; `clearWeather` clears the sky at once and keeps it clear; `fastUI`
---   draws the UI at its highest rate until `done()`, which puts the option back.
--- - `onStart(mode)`: optional, called after the scenario's own onStart in every mode.
--- - `tests`: settings of the test library, see PZHarness/TestLib.lua.
--- With --mp no scenario starts: the client joins the server, the runner takes the character to
--- the scenario's `startLoc` and calls its onStart and the mod's (see Multiplayer above).
function PZHarness.register(config)
    PZHarness.config = {
        scenario = config.scenario,
        prefix = config.prefix or "",
        modes = config.modes or {},
        onStart = config.onStart,
        tests = config.tests or {},
    }
    local scenario = debugScenarios[config.scenario]
    if run.mode == "" then
        wrapSetSandbox(scenario, "")
        return
    end
    -- run-client.sh times the game's boot up to the first of these; --mp prints one again after
    -- joining resets the Lua.
    print("PZHarness: the dev mod registered for " .. run.mode)

    -- Single player pauses when the window loses focus, and paused games don't tick, so the run
    -- would stop whenever someone switches to another window.
    getCore():setOptionPauseOnFocusloss(false)

    -- Game time per second doesn't depend on the frame rate (FPSTracking), so more frames a second
    -- only shorten what is counted in ticks: the tests' waits for the game to apply a change, and
    -- from here on the world loading. Measured on an M3 Max, uncapped draws about 260 frames a
    -- second against 60. The option can't do it: Core.loadOptions resets uncappedFPS to false and
    -- frameRate to 60. Every mode loads uncapped: the main menu and the loading screen step per
    -- frame, and the game takes at most 16 loaded assets a frame. A mode whose steps wait fixed
    -- tick counts goes back to 60 when the scenario starts, before its first step.
    local mode = PZHarness.config.modes[run.mode]
    local uncapped = run.mode == "test" or (mode and mode.uncapped)
    getPerformance():setFramerateUncapped(true)
    if run.mp then
        return
    end

    scenario.forceLaunch = true
    wrapSetSandbox(scenario, run.mode == "test" and run.quiet or "")

    local originalOnStart = scenario.onStart
    scenario.onStart = function()
        if not uncapped then
            getPerformance():setFramerateUncapped(false)
        end
        originalOnStart()
        if PZHarness.config.onStart then
            PZHarness.config.onStart(run.mode)
        end
        afterSettling(startMode)
    end
end

return PZHarness
