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

local function actionClass()
    local setting = PZHarness.testSettings.jobAction
    return need(setting and setting(), "the jobAction test setting, the mod's job action class")
end

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

-- T.job: the job `args.job` of the action's feature `args.feature` at its target on the square at
-- `args.at` (the target of the feature `args.targetOf` there if given, as for a job the action
-- must turn down; the square's floor with `args.floor`), with `args.with` (withOf), as the server's
-- character. `args.via` "job" (the default) does it as the action's complete() does once the
-- character is found at it (completeJob); "complete" builds the action as the server builds a
-- client's and runs its complete(), its keeps() and reach included; with `args.build` the action
-- is only built. A forged place with no target answers { ok = false, reason = "no <feature>" }, as
-- keeps() turns it down. Answers `ok`, else the `reason` the job module refuses it for as the
-- authority knows it after; `built`; the XP in the perks `args.xp` before and after (`xpBefore`,
-- `xpAfter`); and `args.reads` read before and after in the same call (PZHarness.readsAround), in
-- `before` and `after`.
handler("PZHarness.job", function(player, args, defer)
    local Action, feature, job = actionClass(), args.feature, args.job
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
