-- Development only, not published. The result lines every part of a test run prints, under the
-- run's tag; docs/running.md lists them and lib/results.py reads them.

require "PZHarness/Run"

local Report = {}

local run = PZHarness.run

-- Failures that arrive after their test's verdict or outside any test, such as a server undo that
-- failed or a multiplayer start's setup, that no DONE line has counted yet: the next one counts
-- them (Schedule), so one before a run's start fails that run too.
Report.lateFailures = 0
-- Whether the harness runner is running the tests: it prints each verdict once the leak check
-- after the test is done, and the test's own validate (TestLib) leaves it to the runner.
Report.runnerOwnsVerdicts = false

function Report.line(kind, text)
    print(run.tag .. " " .. kind .. " " .. text)
end

--- "<tag> PASS <name> (<s> s)", or FAIL with `failures` as its reasons.
function Report.verdict(name, failures, seconds)
    local took = string.format(" (%.2f s)", seconds)
    if #failures > 0 then
        Report.line("FAIL", name .. ": " .. table.concat(failures, "; ") .. took)
    else
        Report.line("PASS", name .. took)
    end
end

--- Prints a failure that came after its test's verdict, or outside any test, such as a server undo
--- or a scenario's setup, as "<tag> FAIL <name>: <why>"; the run's DONE line counts it.
function Report.lateFailure(name, why)
    Report.line("FAIL", name .. ": " .. why)
    Report.lateFailures = Report.lateFailures + 1
end

return Report
