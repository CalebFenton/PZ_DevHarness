-- Development only, not published. Expectations: a test's validate (client/PZHarness/TestLib.lua's
-- T.expect, expectNear and expectEqual) and a dev mod's server check handler, which checks many
-- things and answers with what it found wrong (server/PZHarness/ServerChecks.lua), both use
-- Checks.new, so the two compare and word a miss the same way.

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

--- Whether `actual` equals `expected`, and the message for when it doesn't, worded as `near`'s.
function Checks.equal(label, actual, expected)
    return actual == expected, label .. " is " .. tostring(actual) .. ", expected " .. tostring(expected)
end

--- A fresh list of failures and the three functions that fill it: `expect(condition, message)`
--- records `message` when `condition` is nil or false; `expectNear(label, actual, expected,
--- tolerance)` records "<label> is <actual>, expected <expected>" when `actual` isn't a number
--- within `tolerance` of `expected`; `expectEqual(label, actual, expected)` records the same words
--- when `actual ~= expected`. Each returns whether the expectation held. Returns `expect,
--- expectNear, expectEqual, failures`.
function Checks.new()
    local failures = {}
    local function expect(condition, message)
        if not condition then
            table.insert(failures, message)
        end
        return condition
    end
    local function expectNear(label, actual, expected, tolerance)
        return expect(Checks.near(label, actual, expected, tolerance))
    end
    local function expectEqual(label, actual, expected)
        return expect(Checks.equal(label, actual, expected))
    end
    return expect, expectNear, expectEqual, failures
end

return Checks
