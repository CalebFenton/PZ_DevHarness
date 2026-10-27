require "PZHarness/ServerHandlers"
require "PZHarness/ServerFixtures"

-- Development only, not published. The authority's half of the job kit
-- (client/PZHarness/TestJobs.lua): a job of the mod's job action done on the authority by the
-- server's character, as the server does the one a client's action asks for. Written against the
-- job action contract cf_commonlib's JobAction.forFeatures gives the class the `jobAction` test
-- setting names, by method name: new(character, feature, job, target, with), complete(),
-- completeJob(character, feature, job, target, with), jobsOf(feature).refusal(character, job,
-- target, with) and targetOn(feature, square).

local handler, need = PZHarness.serverHandler, PZHarness.need

-- The target of `feature` on the square at `at`, or with `floor` the square's floor, which some
-- features work at; nil, also while the square isn't loaded.
local function targetAt(Action, feature, at, floor)
    local square = PZHarness.Fixtures.squareAt(at)
    if floor then
        return square and square:getFloor()
    end
    return square and Action.targetOn(feature, square)
end

-- What the job works with, found in the call's turn, so that the call needs no earlier answer:
-- for `with` { type, inTarget }, the first such item the character carries, or with inTarget the
-- first in the target's container; for { id }, the character's item with that id; for
-- { x, y, z, feature }, that feature's target there; else `with` itself (a name, a slot).
local function withOf(Action, player, with, target)
    if type(with) ~= "table" then
        return with
    elseif with.feature then
        return targetAt(Action, with.feature, with)
    elseif with.id then
        return need(player:getInventory():getItemWithIDRecursiv(with.id), "the server's copy of item " .. tostring(with.id))
    end
    local item = with.inTarget and target:getContainer():getFirstType(with.type)
        or not with.inTarget and player:getInventory():getFirstTypeRecurse(with.type)
    return need(item, "a " .. tostring(with.type) .. (with.inTarget and " in the target" or " on the character") .. " on the server")
end

-- The character's XP in each of `perks` (Perks field names), by name.
local function xpIn(player, perks)
    local xp = {}
    for _, name in ipairs(perks or {}) do
        xp[name] = player:getXp():getXP(need(Perks[name], "the perk " .. tostring(name)))
    end
    return xp
end

-- T.job, as the server's character. A forged place with no target answers { ok = false, reason =
-- "no <feature>" }, as keeps() turns it down; a refused job's `reason` is the job module's as the
-- authority knows it after.
handler("PZHarness.job", function(player, args, defer)
    local setting = PZHarness.testSettings.jobAction
    local Action = need(setting and setting(), "the jobAction test setting, the mod's job action class")
    local feature, job = args.feature, args.job
    local target = targetAt(Action, args.targetOf or feature, args.at, args.floor)
    if not target then
        return { ok = false, reason = "no " .. tostring(feature) }
    end
    local with = withOf(Action, player, args.with, target)
    if args.build then
        return { built = Action:new(player, feature, job, target, with) ~= nil }
    end
    local xpBefore = xpIn(player, args.xp)
    local before, after, done = PZHarness.readsAround(player, args.reads, defer, function()
        if args.via == "complete" then
            local action = Action:new(player, feature, job, target, with)
            return action ~= nil and action:complete() == true
        end
        return Action.completeJob(player, feature, job, target, with) == true
    end)
    return { ok = done, reason = not done and Action.jobsOf(feature).refusal(player, job, target, with) or nil,
        xpBefore = xpBefore, xpAfter = xpIn(player, args.xp), before = before, after = after }
end)
