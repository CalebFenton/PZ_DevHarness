-- Development only, not published. Runs the selected tests one after another, with the character
-- reset, the leak check (Leaks.lua) and the verdict between each test and the next.

require "PZHarness/ServerCalls"
require "PZHarness/Fixtures"
require "PZHarness/Leaks"
require "PZHarness/Trace"
require "PZHarness/TestLib"
local Run = require "PZHarness/Run"
local Report = require "PZHarness/Report"

local Schedule = {}

local run = PZHarness.run

-- How long a test waits for the character's square to load after the last test took it far away.
local SQUARE_WAIT_MS = 10000
-- A test still busy after this many real seconds fails with what it was waiting on, its queue is
-- cleared and its undos run, so one hung step can't stall the run. A spec's `timeoutSeconds`
-- raises it for a test that is slow on purpose.
local TEST_TIMEOUT_SECONDS = 30
-- How much further than TestLib's SEARCH_RADIUS the leak check looks, unless the dev mod sets
-- `leakRadius`.
local LEAK_MARGIN = 2
-- At most this many LEAK and DESYNC lines per test, and DIRTY lines per run; a count of the rest
-- follows.
local LEAK_LINES_SHOWN = 10
-- How many of the slowest tests the run's summary names.
local SLOWEST_COUNT = 10

-- What the last run in this game left behind, as "<test>: <what>", which a kept game's next run
-- reports first: it is still in the world that run starts from.
local leftBehind = {}

-- Selection

-- Whether test `name`, registered as `entry`, matches `filter`: a name prefix, an exact name
-- written "=<name>" (--failed), or "@<file>", the tests the file of that name registered
-- (--changed; TestLib records each test's file).
local function matchesFilter(name, entry, filter)
    local exact = string.match(filter, "^=(.*)$")
    if exact then
        return exact == name
    end
    local file = string.match(filter, "^@(.*)$")
    if file then
        return entry.file == file
    end
    return luautils.stringStarts(name, filter)
end

-- Whether the mod of id `id` is active. Build 42 may list an id with the backslash its mod.info's
-- require lines put before one.
local function modActive(id)
    local mods = getActivatedMods()
    for i = 0, mods:size() - 1 do
        local active = mods:get(i)
        if active == id or active == "\\" .. id then
            return true
        end
    end
    return false
end

-- Why the test `entry` doesn't run in this game, or nil: the mod its spec needs isn't loaded
-- (TestLib's needsMod), or its opt-out (spOnly and mpOnly) for the other mode.
local function skipReason(entry)
    if entry.needsMod and not modActive(entry.needsMod) then
        return "needs the mod " .. entry.needsMod .. ", which this run doesn't load (EXTRA_MODS)"
    end
    if isClient() then
        return entry.spOnly and "single player only: " .. entry.spOnly
    end
    return entry.mpOnly and "multiplayer only: " .. entry.mpOnly
end

-- The tests of the mod that `selection` (comma-separated filters; empty for every test) picks,
-- and those skipped in this mode as "<name>: <why>", both sorted; then the filters that name no
-- test at all, such as a typo or a TEST_MAP entry for a test that has since been renamed.
local function testNames(selection)
    local filters = {}
    for filter in string.gmatch(selection or "", "[^,%s]+") do
        table.insert(filters, filter)
    end
    local result, skipped, used = {}, {}, {}
    for name, entry in pairs(TimedActionTests.getTests()) do
        local picked = false
        if luautils.stringStarts(name, PZHarness.config.prefix) then
            picked = #filters == 0
            for _, filter in ipairs(filters) do
                if matchesFilter(name, entry, filter) then
                    picked, used[filter] = true, true
                end
            end
        end
        if picked then
            local reason = skipReason(entry)
            table.insert(reason and skipped or result, reason and name .. ": " .. reason or name)
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

-- Seeded random integer in 1..n (Park-Miller; products stay exact in a double), since ZombRand
-- can't be seeded.
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

-- The state machine

-- Prints test `name`'s verdict and counts it for the DONE line and the REPEAT tally.
local function printVerdict(state, name, failures, seconds)
    Report.verdict(name, failures, seconds)
    local tally = state.tally[name] or { passed = 0, failed = 0 }
    state.tally[name] = tally
    if #failures == 0 then
        state.passed, tally.passed = state.passed + 1, tally.passed + 1
    else
        state.failed, tally.failed = state.failed + 1, tally.failed + 1
    end
end

-- Prints the verdict of the test that just ended, once the leak check after it is done: its LEAK
-- and DESYNC lines first, which with LEAKS=fail also fail it.
local function settleVerdict(state, found)
    local ended = state.verdict
    state.verdict = nil
    if not ended then
        return
    end
    local failures = ended.failures
    local findings = {}
    for _, line in ipairs(found and found.leaks or {}) do
        table.insert(findings, { kind = "LEAK", line = line, failure = "left behind " .. line })
    end
    for _, line in ipairs(found and found.desyncs or {}) do
        table.insert(findings, { kind = "DESYNC", line = line, failure = "client and server differ at " .. line })
    end
    for i, finding in ipairs(findings) do
        if i > LEAK_LINES_SHOWN then
            local rest = #findings - LEAK_LINES_SHOWN
            Report.line("LEAK", string.format("%s: and %d more", ended.name, rest))
            if state.leaks == "fail" then
                table.insert(failures, rest .. " more leaks and desyncs")
            end
            break
        end
        Report.line(finding.kind, ended.name .. ": " .. finding.line)
        table.insert(leftBehind, ended.name .. ": " .. finding.line)
        if state.leaks == "fail" then
            table.insert(failures, finding.failure)
        end
    end
    printVerdict(state, ended.name, failures, ended.seconds)
end

-- What the server does between tests, sent behind the ended test's undos so it all comes back in
-- one round trip (the server handles a client's requests in order): in multiplayer the character
-- reset, then the leak check's request (Leaks.start) around `at`. Answers arrive in the same order,
-- so once the reset answers, the client half of the leak check can start.
local function askBetweenTests(state, at)
    local nextIndex = state.index + 1
    state.askedFor, state.resetAnswered = nextIndex, false
    local checking = state.leaks ~= "off"
    if isClient() and (state.names[nextIndex] or checking) then
        PZHarness.ServerCalls.callOutsideTest("PZHarness.reset", {}, function() state.resetAnswered = true end)
    end
    if checking then
        state.check = PZHarness.Leaks.start(state.player, at, state.leakRadius, state.leakLevels, state.leakIgnore)
    end
end

-- The current test is done once its action queue is empty, or stopped once it overruns its time
-- limit, in which case validate() fails it with what it was waiting on. Its verdict waits for the
-- leak check (settleVerdict).
local function finishCurrentTest(state)
    local current, player = state.current, state.player
    local queue = ISTimedActionQueue.getTimedActionQueue(player).queue
    PZHarness.Trace.observe(state.name, queue[1], state.ticks)
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
    PZHarness.Trace.observe(state.name, nil, state.ticks)
    PZHarness.Trace.test(state.name, state.testStartMs, state.doneMs, state.ticks - state.testStartTicks)
    -- TestLib's validate leaves its failures and the test's time; a test registered some other way
    -- has only its verdict.
    local seconds = current.seconds or (state.doneMs - state.testStartMs) / 1000
    state.verdict = { name = state.name, seconds = seconds,
        failures = current.failures or (passed and {} or { "validate failed" }) }
    table.insert(state.times, { name = state.name, seconds = seconds,
        serverSeconds = (PZHarness.ServerCalls.waitedMs() - state.testServerMs) / 1000 })
    ISBuildMenu.cheat = state.wasCheat
    PZHarness.Fixtures.teleportToMiddle(player, state.start.x, state.start.y, state.start.z)
    askBetweenTests(state, state.start)
end

-- Whether the leak check, then the next test, may start: the character's square has reloaded (or
-- SQUARE_WAIT_MS passed), and the server has answered everything the last test sent, its undos
-- above all, so a test never meets what the previous one built.
local function readyForNextTest(state)
    local here = state.player:getCurrentSquare()
    if not here and getTimestampMs() - state.doneMs < SQUARE_WAIT_MS then
        return false
    end
    if state.askedFor ~= state.index + 1 then
        askBetweenTests(state, here and { x = here:getX(), y = here:getY(), z = here:getZ() })
    end
    -- A reset that failed never answers; its FAIL line counts in the run's verdict.
    return state.resetAnswered or not PZHarness.ServerCalls.busy()
end

-- Between tests: the character reset, then the leak check, then the ended test's verdict. True once
-- all of it is done.
local function checkBetweenTests(state)
    if state.checkedFor == state.index then
        return true
    end
    if state.resetFor ~= state.index then
        state.resetFor = state.index
        -- Before the snapshot, so what the reset takes away doesn't count as left behind.
        PZHarness.Fixtures.resetCharacter(state.player)
        PZHarness.Test.refreshInventoryWindows()
        if not state.check then
            settleVerdict(state, nil)
            state.checkedFor = state.index
            return true
        end
        state.checkStartMs = getTimestampMs()
        PZHarness.Trace.gap("reset", state.doneMs, state.checkStartMs)
    end
    local found = state.check()
    if not found then
        return false
    end
    state.check = nil
    state.leakMs = state.leakMs + getTimestampMs() - state.checkStartMs
    PZHarness.Trace.gap("leaks", state.checkStartMs, getTimestampMs())
    if found.waitedFull then
        state.leakWaitedFull = state.leakWaitedFull + 1
    end
    settleVerdict(state, found)
    state.checkedFor = state.index
    return true
end

-- Starts test `name` from the freshly reset character's square. If that square still hasn't
-- loaded since the last test went far, the test fails without running, since the character
-- couldn't be brought back to its start.
local function startNextTest(state, name)
    local player = state.player
    state.gapMs = state.gapMs + getTimestampMs() - state.doneMs
    print("TEST: " .. name)
    local here = player:getCurrentSquare()
    if not here then
        printVerdict(state, name, { string.format("the character's square was still unloaded %d s after the last test",
            SQUARE_WAIT_MS / 1000) }, 0)
        state.doneMs = getTimestampMs()
        return
    end
    state.name = name
    state.current = state.tests[name]
    state.start = { x = here:getX(), y = here:getY(), z = here:getZ() }
    player:Say(name)
    state.wasCheat = ISBuildMenu.cheat
    ISBuildMenu.cheat = false
    state.testStartMs, state.testStartTicks = getTimestampMs(), state.ticks
    state.testServerMs = PZHarness.ServerCalls.waitedMs()
    state.current:run()
end

-- Prints `lines` as "<tag> <kind> <line>", at most LEAK_LINES_SHOWN of them, then how many more.
local function printCapped(kind, lines)
    for i, text in ipairs(lines) do
        if i > LEAK_LINES_SHOWN then
            Report.line(kind, string.format("and %d more", #lines - LEAK_LINES_SHOWN))
            return
        end
        Report.line(kind, text)
    end
end

-- With REPEAT, how often each test passed and failed, the most failed first.
local function printTally(tally)
    local names = {}
    for name in pairs(tally) do
        table.insert(names, name)
    end
    table.sort(names, function(a, b)
        if tally[a].failed ~= tally[b].failed then
            return tally[a].failed > tally[b].failed
        end
        return a < b
    end)
    for _, name in ipairs(names) do
        Report.line("REPEAT", string.format("%s passed=%d failed=%d", name, tally[name].passed, tally[name].failed))
    end
end

-- Prints the slowest tests, then where the run's time went: in tests, between them, and in
-- multiplayer how much of it waited on the server.
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
            Report.line("SLOWEST", string.format("%.2f s %s%s", entry.seconds, entry.name,
                isClient() and string.format(" (server %.2f s)", entry.serverSeconds) or ""))
        end
    end
    local summary = string.format("%.1f s in tests, %.1f s between them (%.1f s of it checking for leaks)",
        inTests, state.gapMs / 1000, state.leakMs / 1000)
    if isClient() then
        summary = summary .. string.format(", %.1f s of it all waiting on the server; %d leak checks waited the full time for this client to catch up",
            (PZHarness.ServerCalls.waitedMs() - state.serverStartMs) / 1000, state.leakWaitedFull)
    end
    Report.line("SLOWEST", summary)
end

-- The run's SKIP, REPEAT, SLOWEST and TIME lines, then DONE, whose failed count takes in the
-- failures that came after their tests' verdicts.
local function finishRun(state)
    Report.runnerOwnsVerdicts = false
    PZHarness.Trace.stop()
    state.gapMs = state.gapMs + getTimestampMs() - state.doneMs
    for _, skip in ipairs(state.skipped) do
        Report.line("SKIP", skip .. " (0.00 s)")
    end
    if state.rounds > 1 then
        printTally(state.tally)
    end
    printSlowest(state)
    local seconds = (getTimestampMs() - state.startedMs) / 1000
    Report.line("TIME", string.format("%.1f s, %d frames (%.0f a second)", seconds, state.ticks,
        state.ticks / math.max(seconds, 0.001)))
    Report.line("DONE", "passed=" .. state.passed .. " failed=" .. (state.failed + Report.lateFailures)
        .. " skipped=" .. #state.skipped)
    Report.lateFailures = 0
    state.onDone()
end

--- Runs the tests `selection` picks (testNames) one after another, with the resets of vanilla's
--- debug-menu runner (Tests/TimedActionsTests.lua, whose locals Lua can't reach): full health,
--- empty inventory, nothing worn or held, cheat off before each test; validate() once the action
--- queue empties; then the cheat and character position restored. Unlike vanilla there is no
--- pause between tests. In multiplayer the server's copy of the character is reset first. Calls
--- onDone() at the end.
function Schedule.runTests(selection, onDone)
    local names, skipped, unmatched = testNames(selection)
    local rounds = math.max(1, tonumber(run.rounds) or 1)
    local order = run.order or ""
    local leaks = run.leaks ~= nil and run.leaks ~= "" and run.leaks or "fail"
    local settings = PZHarness.testSettings
    local leakRadius = settings.leakRadius or PZHarness.Test.SEARCH_RADIUS + LEAK_MARGIN
    local leakIgnore = {}
    for _, list in ipairs({ PZHarness.Snapshot.DEFAULT_IGNORE, settings.leakIgnore or {} }) do
        for _, pattern in ipairs(list) do
            table.insert(leakIgnore, pattern)
        end
    end
    if #leftBehind > 0 then
        printCapped("DIRTY", leftBehind)
        leftBehind = {}
    end
    names = orderedRounds(names, order, rounds)
    Report.line("START", tostring(#names))
    if order ~= "" then
        Report.line("ORDER", order)
    end
    if rounds > 1 then
        Report.line("REPEAT", rounds .. " rounds")
    end
    Report.line("LEAKS", leaks .. (leaks ~= "off" and ", " .. leakRadius .. " squares around the character" or ""))
    for _, filter in ipairs(unmatched) do
        Report.line("FAIL", filter .. ": the selection names no test")
    end
    local tests = TimedActionTests.getTests()
    Run.writeTestFiles(tests)
    PZHarness.Leaks.reset()
    if run.trace ~= nil and run.trace ~= "" then
        PZHarness.Trace.start()
    end
    Report.runnerOwnsVerdicts = true
    local startedMs = getTimestampMs()
    -- `start` holds where the current test started, as numbers: the square object itself goes back
    -- to the pool when a test takes the character far enough for its chunk to unload, and comes
    -- back as some other square (IsoGridSquare.discard, getNew), so teleporting to its coordinates
    -- then lands somewhere else entirely.
    local state = {
        names = names, skipped = skipped, tests = tests, onDone = onDone, rounds = rounds,
        leaks = leaks, leakRadius = leakRadius, leakLevels = settings.leakLevels, leakIgnore = leakIgnore,
        passed = 0, failed = #unmatched, index = 0, ticks = 0, startedMs = startedMs, doneMs = startedMs,
        -- For the summary: per-test timings, time between tests and its leak-check share, server
        -- waits (accumulated across a kept game's runs) and per-test pass/fail counts.
        times = {}, gapMs = 0, leakMs = 0, leakWaitedFull = 0, serverStartMs = PZHarness.ServerCalls.waitedMs(), tally = {},
        current = nil, name = nil, player = nil, start = nil, wasCheat = nil,
        testStartMs = nil, testStartTicks = nil, testServerMs = nil,
        -- Between-tests bookkeeping: which test index the server request was sent for and whether
        -- its reset answered, the pending verdict, and the leak check under way.
        askedFor = nil, resetAnswered = false, resetFor = nil, verdict = nil, check = nil, checkStartMs = nil, checkedFor = nil,
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

return Schedule
