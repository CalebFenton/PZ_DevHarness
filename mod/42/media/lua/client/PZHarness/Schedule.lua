-- Development only, not published. Runs the selected tests one after another, ticking through
-- each test, the character reset, the leak check (Leaks.lua) and the test's verdict (Report.lua)
-- before the next test starts.

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

-- Why the test `entry` doesn't run in this game, or nil: the opt-out of its spec (TestLib's
-- spOnly and mpOnly) for the other mode.
local function skipReason(entry)
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

-- Prints the verdict of the test that just ended, once the leak check after it is done: its LEAK
-- and DESYNC lines first, which with LEAKS=fail also fail it.
local function settleVerdict(state, found)
    local verdict = state.verdict
    state.verdict = nil
    if not verdict then
        return
    end
    Report.findings(verdict.name, PZHarness.Leaks.findings(found), state.leaks == "fail", verdict.failures)
    Report.verdict(verdict.name, verdict.failures, verdict.seconds)
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
-- limit, in which case validate() fails it with what it was waiting on. Its verdict then waits
-- for the leak check (settleVerdict); timings go to the summary, cheat and character are restored,
-- and the between-tests request goes out.
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
    Report.time(state.name, seconds, (PZHarness.ServerCalls.waitedMs() - state.testServerMs) / 1000)
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

-- Between tests: the character reset, then the leak check (PZHarness/Leaks.lua), then the ended
-- test's verdict. Returns true once all of it is done. A check whose square never loaded finds
-- nothing and restarts the baselines.
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
        Report.verdict(name, { string.format("the character's square was still unloaded %d s after the last test",
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

-- Prints the run's summary and verdict, then calls onDone().
local function finishRun(state)
    PZHarness.Trace.stop()
    state.gapMs = state.gapMs + getTimestampMs() - state.doneMs
    Report.finishRun({
        gapMs = state.gapMs, leakMs = state.leakMs, leakWaitedFull = state.leakWaitedFull,
        serverMs = PZHarness.ServerCalls.waitedMs() - state.serverStartMs,
        seconds = (getTimestampMs() - state.startedMs) / 1000, ticks = state.ticks,
    })
    state.onDone()
end

--- Runs the tests `selection` picks (comma-separated name prefixes, "=<name>" and "@<file>"
--- entries; empty for every test of the mod) one after another, with the resets of vanilla's
--- debug-menu runner (Tests/TimedActionsTests.lua, whose locals Lua can't reach): full health,
--- empty inventory, nothing worn or held, cheat off before each test; validate() once the action
--- queue empties; then the cheat and character position restored. Unlike vanilla there is no
--- pause between tests. In multiplayer the server's copy of the character is reset first. Calls
--- onDone() at the end.
function Schedule.runTests(selection, onDone)
    local names, skipped, unmatched = testNames(selection)
    local rounds = math.max(1, tonumber(run.rounds) or 1)
    local order = run.order or ""
    local leaks, leakRadius, leakLevels, leakIgnore = PZHarness.Leaks.settings()
    names = orderedRounds(names, order, rounds)
    Report.startRun(#names, { order = order, rounds = rounds, leaks = leaks, leakRadius = leakRadius }, skipped, unmatched)
    local tests = TimedActionTests.getTests()
    Run.writeTestFiles(tests)
    PZHarness.Leaks.reset()
    if run.trace ~= nil and run.trace ~= "" then
        PZHarness.Trace.start()
    end
    local startedMs = getTimestampMs()
    -- `start` holds where the current test started, as numbers: the square object itself goes back
    -- to the pool when a test takes the character far enough for its chunk to unload, and comes
    -- back as some other square (IsoGridSquare.discard, getNew), so teleporting to its coordinates
    -- then lands somewhere else entirely.
    local state = {
        names = names, tests = tests, onDone = onDone,
        leaks = leaks, leakRadius = leakRadius, leakLevels = leakLevels, leakIgnore = leakIgnore,
        index = 0, ticks = 0, startedMs = startedMs, doneMs = startedMs,
        -- For the summary: time between tests and its leak-check share, and server waits
        -- (accumulated across a kept game's runs).
        gapMs = 0, leakMs = 0, leakWaitedFull = 0, serverStartMs = PZHarness.ServerCalls.waitedMs(),
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

--- Forgets every test of the mod, so a --stay rerun that loads the test files again doesn't run
--- renamed or deleted ones.
function Schedule.unregisterTests()
    local tests = TimedActionTests.getTests()
    local registered = {}
    for name in pairs(tests) do
        if luautils.stringStarts(name, PZHarness.config.prefix) then
            table.insert(registered, name)
        end
    end
    for _, name in ipairs(registered) do
        tests[name] = nil
    end
end

return Schedule
