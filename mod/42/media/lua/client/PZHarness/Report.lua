-- Development only, not published. Every result line of a test run, under the run's tag, and the
-- counts behind its DONE line. docs/running.md lists the lines; lib/results.py reads them.

require "PZHarness/Run"

local Report = {}

local run = PZHarness.run

-- At most this many LEAK and DESYNC lines per test, and DIRTY lines per run; a count of the rest
-- follows.
local LEAK_LINES_SHOWN = 10
-- How many of the slowest tests the run's summary names.
local SLOWEST_COUNT = 10

-- Failures that arrive after their test's verdict, such as a server undo that failed, over the
-- game's life; a run's DONE line counts those since its start.
local lateFailures = 0
-- What the last run in this game left behind, as "<test>: <what>", which a kept game's next run
-- reports first: it is still in the world that run starts from.
local leftBehind = {}
-- The run under way: its counts, per-test timings and REPEAT tally; nil outside one, as when the
-- debug menu's runner runs the tests.
local current

local function took(seconds)
    return string.format(" (%.2f s)", seconds)
end

local function line(kind, text)
    print(run.tag .. " " .. kind .. " " .. text)
end

--- Whether the harness runner is running the tests: it prints each verdict once the leak check
--- after the test is done, and the test's own validate (TestLib) leaves it to the runner.
function Report.runnerOwnsVerdicts()
    return current ~= nil
end

--- Prints a test's verdict, "<tag> PASS <name> (<s> s)" or FAIL with `failures` as its reasons,
--- and counts it in the run under way.
function Report.verdict(name, failures, seconds)
    if #failures > 0 then
        line("FAIL", name .. ": " .. table.concat(failures, "; ") .. took(seconds))
    else
        line("PASS", name .. took(seconds))
    end
    if not current then
        return
    end
    local tally = current.tally[name] or { passed = 0, failed = 0 }
    current.tally[name] = tally
    if #failures == 0 then
        current.passed, tally.passed = current.passed + 1, tally.passed + 1
    else
        current.failed, tally.failed = current.failed + 1, tally.failed + 1
    end
end

--- Prints a failure that came after its test's verdict, or outside any test, such as a server undo
--- or a scenario's setup, as "<tag> FAIL <name>: <why>"; the run's DONE line counts it.
function Report.lateFailure(name, why)
    line("FAIL", name .. ": " .. why)
    lateFailures = lateFailures + 1
end

-- Prints `lines` as "<tag> <kind> <line>", at most LEAK_LINES_SHOWN of them, then how many more.
local function printCapped(kind, lines)
    for i, text in ipairs(lines) do
        if i > LEAK_LINES_SHOWN then
            line(kind, string.format("and %d more", #lines - LEAK_LINES_SHOWN))
            return
        end
        line(kind, text)
    end
end

--- Starts a run of `count` tests: prints what the last run in this game left behind, START and the
--- run's `settings` (order, rounds, leaks, leakRadius), and a FAIL for each entry of the selection
--- that names no test (`unmatched`). `skipped` ("<name>: <why>") print as SKIP lines at the end.
function Report.startRun(count, settings, skipped, unmatched)
    if #leftBehind > 0 then
        printCapped("DIRTY", leftBehind)
        leftBehind = {}
    end
    line("START", tostring(count))
    if settings.order ~= "" then
        line("ORDER", settings.order)
    end
    if settings.rounds > 1 then
        line("REPEAT", settings.rounds .. " rounds")
    end
    line("LEAKS", settings.leaks .. (settings.leaks ~= "off" and ", " .. settings.leakRadius .. " squares around the character" or ""))
    for _, filter in ipairs(unmatched) do
        line("FAIL", filter .. ": the selection names no test")
    end
    current = { passed = 0, failed = #unmatched, skipped = skipped, rounds = settings.rounds, tally = {}, times = {},
        lateAtStart = lateFailures }
end

--- Prints what the leak check after test `name` found (Leaks.findings) as LEAK and DESYNC lines, at
--- most LEAK_LINES_SHOWN then a count of the rest, and keeps them for the next run's DIRTY lines.
--- With `failing` (LEAKS=fail) each one shown, and the count of the rest, joins `failures`.
function Report.findings(name, findings, failing, failures)
    for i, finding in ipairs(findings) do
        if i > LEAK_LINES_SHOWN then
            local rest = #findings - LEAK_LINES_SHOWN
            line("LEAK", string.format("%s: and %d more", name, rest))
            if failing then
                table.insert(failures, rest .. " more leaks and desyncs")
            end
            return
        end
        line(finding.kind, name .. ": " .. finding.line)
        table.insert(leftBehind, name .. ": " .. finding.line)
        if failing then
            table.insert(failures, finding.failure)
        end
    end
end

--- Records a test's wall time, and in multiplayer how much of it waited on the server, for the
--- SLOWEST lines.
function Report.time(name, seconds, serverSeconds)
    table.insert(current.times, { name = name, seconds = seconds, serverSeconds = serverSeconds })
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
        line("REPEAT", string.format("%s passed=%d failed=%d", name, tally[name].passed, tally[name].failed))
    end
end

-- Prints the slowest tests, then where the run's time went: in tests, between them, and in
-- multiplayer how much of it waited on the server.
local function printSlowest(times, stats)
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
            line("SLOWEST", string.format("%.2f s %s%s", entry.seconds, entry.name,
                isClient() and string.format(" (server %.2f s)", entry.serverSeconds) or ""))
        end
    end
    local summary = string.format("%.1f s in tests, %.1f s between them (%.1f s of it checking for leaks)",
        inTests, stats.gapMs / 1000, stats.leakMs / 1000)
    if isClient() then
        summary = summary .. string.format(", %.1f s of it all waiting on the server; %d leak checks waited the full time for this client to catch up",
            stats.serverMs / 1000, stats.leakWaitedFull)
    end
    line("SLOWEST", summary)
end

--- Ends the run: its SKIP lines, the REPEAT tally, the SLOWEST and TIME lines, then DONE, whose
--- failed count takes in the failures that came after their tests' verdicts. `stats`: gapMs and
--- leakMs (between tests, and checking for leaks), serverMs and leakWaitedFull (multiplayer),
--- seconds and ticks (the whole run).
function Report.finishRun(stats)
    local counts = current
    current = nil
    for _, skip in ipairs(counts.skipped) do
        line("SKIP", skip .. took(0))
    end
    if counts.rounds > 1 then
        printTally(counts.tally)
    end
    printSlowest(counts.times, stats)
    line("TIME", string.format("%.1f s, %d frames (%.0f a second)", stats.seconds, stats.ticks,
        stats.ticks / math.max(stats.seconds, 0.001)))
    line("DONE", "passed=" .. counts.passed .. " failed=" .. (counts.failed + lateFailures - counts.lateAtStart)
        .. " skipped=" .. #counts.skipped)
end

return Report
