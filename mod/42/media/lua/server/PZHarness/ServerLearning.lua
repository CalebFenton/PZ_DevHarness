require "PZHarness/ServerHandlers"
require "PZHarness/Fixtures"

-- Development only, not published. The authority's half of the test library's recipe learning
-- (client/PZHarness/TestLearning.lua): its copy of the character is the one builds and crafts ask,
-- and the one whose XP award levels a perk up. Single player calls these on its one copy.

PZHarness = PZHarness or {}

local Fixtures = PZHarness.Fixtures
local handler = PZHarness.serverHandler

-- The character's level of each perk `levels` names (perk id -> level) and of `also`, by perk id.
local function levelsNow(player, levels, also)
    local now = {}
    local function note(id)
        local perk = Perks.FromString(id)
        if perk and perk ~= Perks.MAX then
            now[id] = player:getPerkLevel(perk)
        end
    end
    for id in pairs(levels or {}) do
        note(id)
    end
    if also then
        note(also)
    end
    return now
end

-- Sets `levels` until the test ends, answering the levels it replaced, which a multiplayer client
-- puts back on its own copy too: the copy that copy syncs from is the authority's.
local function setLevelsUntilEnd(player, levels, also, defer)
    local saved = levelsNow(player, levels, also)
    defer(function() Fixtures.setPerkLevels(player, saved) end)
    Fixtures.setPerkLevels(player, levels or {})
    return saved
end

-- T.knowRecipes: the character knows (`args.known`) or forgets `args.names` until the test ends.
handler("PZHarness.knowRecipes", function(player, args, defer)
    defer(Fixtures.knowRecipes(player, args.names, args.known))
    return {}
end)

-- Whether the authority's copy of the character knows each of `args.names`, in `known` by name.
handler("PZHarness.recipesKnown", function(player, args)
    return { known = Fixtures.knows(player, args.names) }
end)

-- T.levelUp: sets the levels `args.levels` (perk id -> level), each at the XP that starts it, then
-- awards the XP that takes `args.perk` one level up, as the authority awards a timed action's XP:
-- the game levels the perk up and fires LevelPerk, which vanilla's AutoLearn and a mod's learning
-- hook run on. Answers the level before and after, and the levels it replaced in `saved`.
handler("PZHarness.levelUp", function(player, args, defer)
    local perk = Perks.FromString(args.perk)
    PZHarness.need(perk and perk ~= Perks.MAX, "the perk " .. tostring(args.perk))
    local saved = setLevelsUntilEnd(player, args.levels, args.perk, defer)
    local before = player:getPerkLevel(perk)
    local next = PerkFactory.getPerk(perk):getTotalXpForLevel(before + 1)
    addXpNoMultiplier(player, perk, next - player:getXp():getXP(perk) + 1)
    return { before = before, after = player:getPerkLevel(perk), saved = saved }
end)

-- T.setLevelsQuietly: sets the levels `args.levels` with no level up, so no LevelPerk teaches
-- anything. Answers what it knows of `args.names` right after, in `known`, and the levels it
-- replaced in `saved`.
handler("PZHarness.setLevelsQuietly", function(player, args, defer)
    local saved = setLevelsUntilEnd(player, args.levels, nil, defer)
    return { known = Fixtures.knows(player, args.names or {}), saved = saved }
end)
