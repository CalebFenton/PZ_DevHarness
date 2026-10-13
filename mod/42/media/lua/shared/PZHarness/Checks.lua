-- Development only, not published. Expectations outside a test's validate, such as a dev mod's
-- server handler that checks many things and answers with what it found wrong. Shared, so the test
-- library's own expectNear (client/PZHarness/TestLib.lua) compares and words a miss the same way.

PZHarness = PZHarness or {}
local Checks = {}
PZHarness.Checks = Checks

-- How far apart two numbers may be and still count as equal, unless a check says otherwise.
local DEFAULT_TOLERANCE = 0.0001

--- Whether `actual` is a number within `tolerance` of `expected`, and the message for when it isn't.
function Checks.near(label, actual, expected, tolerance)
    local ok = type(actual) == "number" and math.abs(actual - expected) <= (tolerance or DEFAULT_TOLERANCE)
    return ok, label .. " is " .. tostring(actual) .. ", expected " .. expected
end

--- A fresh list of failures and the two functions that fill it: `expect(condition, message)`
--- records `message` when `condition` is nil or false, and `expectNear(label, actual, expected,
--- tolerance)` records "<label> is <actual>, expected <expected>" when `actual` isn't a number
--- within `tolerance` of `expected`. Both return whether the expectation held. Returns `expect,
--- expectNear, failures`.
function Checks.new()
    local failures = {}
    local function expect(condition, message)
        if not condition then
            table.insert(failures, message)
        end
        return condition
    end
    local function expectNear(label, actual, expected, tolerance)
        local ok, message = Checks.near(label, actual, expected, tolerance)
        return expect(ok, message)
    end
    return expect, expectNear, failures
end

return Checks
