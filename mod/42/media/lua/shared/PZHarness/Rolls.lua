require "PZHarness/Fixtures"

-- Development only, not published. Setting the rolls a mod's chances draw, so a test checks either
-- side of a chance in one try each instead of rolling it many times. The mod's `chance` test
-- setting names its roll module, whose `roll()` every chance looks up on the module as it runs.
-- Shared, so a dev mod's server handlers and its client tests work out the same rolls.

PZHarness = PZHarness or {}
local Rolls = {}
PZHarness.Rolls = Rolls

local Fixtures = PZHarness.Fixtures

--- How far under a chance a roll still comes in under it.
Rolls.UNDER = 1e-9

local function chance()
    local setting = PZHarness.testSettings.chance
    return PZHarness.need(setting and setting(), "the chance test setting, the mod's roll module")
end

-- The game's roll, kept while a test sets its own; and the rolls tests set, so that setting one
-- over another still keeps the game's.
local gameRoll, setRolls = nil, {}

--- Sets what the mod's roll gives until the test ends: `rolls` a number, every roll; or a list, the
--- next rolls in order, and an error once they run out, so a draw the test didn't expect shows. The
--- error puts the game's roll back first, so the draws after it, a pass's or a tick's, roll as
--- usual. Returns the function that puts back the roll before; Fixtures.deferOnce says when it runs.
--- In a server handler.
function Rolls.force(defer, rolls)
    local module = chance()
    if not setRolls[module.roll] then
        gameRoll = module.roll
    end
    local drawn = 0
    local roll = type(rolls) == "number" and function() return rolls end or function()
        drawn = drawn + 1
        if rolls[drawn] == nil then
            module.roll = gameRoll
            error("a roll past the " .. #rolls .. " the test set")
        end
        return rolls[drawn]
    end
    setRolls[roll] = true
    return Fixtures.replace(defer, module, "roll", roll)
end

--- Runs fn(...) with the rolls `rolls` (Rolls.force), then puts the roll before back. Returns what
--- fn returns.
function Rolls.with(defer, rolls, fn, ...)
    local restore = Rolls.force(defer, rolls)
    local results = { fn(...) }
    restore()
    return unpack(results)
end

--- Runs run(trial) for each of `trials` with the rolls rollsOf(trial) gives (Rolls.with). Returns
--- what each run returned, in order.
function Rolls.eachTrial(defer, trials, rollsOf, run)
    local results = {}
    for i, trial in ipairs(trials) do
        results[i] = Rolls.with(defer, rollsOf(trial), run, trial)
    end
    return results
end

--- `roll` as a trial gives it: "under" or "at" for just under or at `chance`, worked out where the
--- chance is known so the roll is exactly the chance, else the number itself.
function Rolls.trialRoll(roll, chance)
    return roll == "under" and chance - Rolls.UNDER or roll == "at" and chance or roll
end

return Rolls
