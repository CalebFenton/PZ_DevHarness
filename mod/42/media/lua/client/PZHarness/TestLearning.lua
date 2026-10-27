require "PZHarness/TestLib"
local Runtime = require "PZHarness/TestRuntime"

-- Development only, not published. Recipe learning for tests: what the character knows, on both
-- sides, and levels set or levelled up the way the game does, each put back when the test ends.
-- The authority's half is server/PZHarness/ServerLearning.lua; single player runs it on its one
-- copy of the character.

local T = PZHarness.Test

local function recipeNames(recipes, prefix)
    prefix = prefix or PZHarness.testSettings.recipePrefix or ""
    local names = {}
    for i = 0, recipes:size() - 1 do
        local name = recipes:get(i):getName()
        if luautils.stringStarts(name, prefix) then
            table.insert(names, name)
        end
    end
    return names
end

--- Every craftRecipe whose name starts with `prefix` (the `recipePrefix` setting by default).
function T.recipeNames(prefix)
    return recipeNames(getScriptManager():getAllCraftRecipes(), prefix)
end

--- Every build menu recipe whose name starts with `prefix` (the `recipePrefix` setting by
--- default): the entities' recipes, which getAllCraftRecipes, and so T.recipeNames, leaves out.
function T.buildRecipeNames(prefix)
    return recipeNames(getScriptManager():getAllBuildableRecipes(), prefix)
end

--- Teaches `player` every recipe whose name starts with `prefix` (the `recipePrefix` setting by
--- default); in multiplayer the server's copy too. Not undone. Callable outside a test, as from a
--- scenario's onStart; in multiplayer it queues a wait for the server, so a craft queued after it
--- starts once the server knows the recipes.
function T.learnRecipes(player, prefix)
    local names = T.recipeNames(prefix)
    PZHarness.Fixtures.learnRecipes(player, names)
    Runtime.outside("PZHarness.learnRecipes", { names = names })
end

--- The opposite of T.learnRecipes. The server sends a client the recipes it learns but never the
--- ones it forgets (SyncPlayerFieldsPacket), so both sides forget them.
function T.forgetRecipes(player, prefix)
    local names = T.recipeNames(prefix)
    PZHarness.Fixtures.forgetRecipes(player, names)
    Runtime.outside("PZHarness.forgetRecipes", { names = names })
end

--- Queues making this client's and the server's copy of the character know (`known`, true when
--- nil) or forget the recipes `names`. When the test ends each side knows exactly the recipes it
--- knew before, including those a level up taught meanwhile, which the leak check counts. Queued
--- again with other names or to forget, it changes only those, and the end still puts back what
--- was known before the first.
function T.knowRecipes(self, names, known)
    known = known ~= false
    if isClient() then
        T.step(function() T.defer(self, PZHarness.Fixtures.knowRecipes(T.player(), names, known)) end)
    end
    T.server(self, "PZHarness.knowRecipes", { names = names, known = known })
end

--- Sets the character's skills to the levels `recipe` requires until the test ends (T.setPerk).
--- With `keepHigher`, retains any higher level. Sets both sides even when the client already
--- has the level: its perk sync can be ahead of the server, which would refuse at perform.
function T.setRecipeSkills(self, recipe, keepHigher)
    local player = T.player()
    for i = 0, recipe:getRequiredSkillCount() - 1 do
        local skill = recipe:getRequiredSkill(i)
        local level = skill:getLevel()
        if keepHigher then level = math.max(player:getPerkLevel(skill:getPerk()), level) end
        T.setPerk(self, skill:getPerk(), level)
    end
end

--- Every craftRecipe and build menu recipe whose name starts with `prefix` (the `recipePrefix`
--- setting by default) that a character has to learn (NeedToBeLearn), each once.
function T.learnableRecipeNames(prefix)
    prefix = prefix or PZHarness.testSettings.recipePrefix or ""
    local names, seen, scripts = {}, {}, getScriptManager()
    for _, recipes in ipairs({ scripts:getAllCraftRecipes(), scripts:getAllBuildableRecipes() }) do
        for i = 0, recipes:size() - 1 do
            local recipe = recipes:get(i)
            local name = recipe:getName()
            if luautils.stringStarts(name, prefix) and recipe:needToBeLearn() and not seen[name] then
                seen[name] = true
                table.insert(names, name)
            end
        end
    end
    return names
end

--- Which of `names` this client's copy of the character knows, by name (Fixtures.knows: by the
--- recipe, as the crafting menus judge it).
function T.recipesKnown(names)
    return PZHarness.Fixtures.knows(T.player(), names)
end

--- Queues waits until the authority's and then this client's copy of the character know each of
--- `names` that `expected` marks true (a multiplayer server sends a client what it taught), and
--- leaves what each side knows of `names` in self.known, { server, client }, for T.expectKnown.
--- Running out of time just ends the server's wait; this client's fails the test as missing.
function T.waitForKnown(self, names, expected)
    local function knowsAll(known)
        for name, want in pairs(expected) do
            if want and not (known and known[name]) then
                return false
            end
        end
        return true
    end
    T.serverUntil(self, "PZHarness.recipesKnown", { names = names }, function(reply) return knowsAll(reply and reply.known) end)
    for name, want in pairs(expected) do
        if want then
            T.waitFor(self, function() return T.recipesKnown({ name })[name] end,
                "this client's copy of the character knowing " .. name)
        end
    end
    T.step(function()
        local reply = self.server["PZHarness.recipesKnown"]
        self.known = { server = reply and reply.known or {}, client = T.recipesKnown(names) }
    end)
end

--- Expects each side of self.known (T.waitForKnown) to know exactly the recipes of `names` that
--- `expected` marks true after `what`.
function T.expectKnown(self, names, what, expected)
    for side, known in pairs(self.known or {}) do
        for _, name in ipairs(names) do
            local want = expected[name] == true
            T.expect(known[name] == want, what .. (want and " did not teach " or " taught ") .. name .. " on the " .. side)
        end
    end
end

-- On a multiplayer client, queues putting this client's copy of the character back at the levels
-- the server's handler `name` answered it replaced, when the test ends: the server puts its own
-- back, but this copy only catches up at its next perk sync (PlayerXpPacket), which the leak check
-- may beat.
local function restoreLevelsHere(self, name)
    if not isClient() then
        return
    end
    T.step(function()
        local saved, p = self.server[name] and self.server[name].saved, T.player()
        if saved then
            T.defer(self, function() PZHarness.Fixtures.setPerkLevels(p, saved) end)
        end
    end)
end

--- Queues setting the authority's levels `levels` (perk id -> level), each at the XP that starts
--- it, then awarding the XP that takes the perk `perk` (an id) one level up, as the authority awards
--- a timed action's XP: the game levels the perk up and fires LevelPerk, so learning on a level up
--- runs as in play. The answer, { before, after } the perk's level, lands in
--- self.server["PZHarness.levelUp"]. The levels go back on both sides when the test ends.
function T.levelUp(self, perk, levels)
    T.server(self, "PZHarness.levelUp", { perk = perk, levels = levels })
    restoreLevelsHere(self, "PZHarness.levelUp")
end

--- Queues setting the authority's levels `levels` (perk id -> level) with no level up, so no
--- LevelPerk teaches anything: a character who earned them before a mod, or its learning, was
--- added. What it knows of `names` right after lands in self.server["PZHarness.setLevelsQuietly"]
--- as `known`, by name. The levels go back on both sides when the test ends.
function T.setLevelsQuietly(self, levels, names)
    T.server(self, "PZHarness.setLevelsQuietly", { levels = levels, names = names })
    restoreLevelsHere(self, "PZHarness.setLevelsQuietly")
end

-- The AutoLearn skills of the recipe `name` as { perk = perk id, level }, in `any` and `all`.
local function autoLearnOf(name)
    local recipe = getScriptManager():getCraftRecipe(name)
    local skills = { any = {}, all = {} }
    if not recipe then return skills end
    for i = 0, recipe:getAutoLearnAnySkillCount() - 1 do
        local skill = recipe:getAutoLearnAnySkill(i)
        table.insert(skills.any, { perk = skill:getPerk():getId(), level = skill:getLevel() })
    end
    for i = 0, recipe:getAutoLearnAllSkillCount() - 1 do
        local skill = recipe:getAutoLearnAllSkill(i)
        table.insert(skills.all, { perk = skill:getPerk():getId(), level = skill:getLevel() })
    end
    return skills
end

--- Every perk and level the AutoLearn skills of the recipes `names` name, once each, as
--- { perk = perk id, level }, and the one with the highest level.
function T.autoLearnLevels(names)
    local rows, seen, highest = {}, {}, nil
    for _, name in ipairs(names) do
        local skills = autoLearnOf(name)
        for _, list in ipairs({ skills.any, skills.all }) do
            for _, skill in ipairs(list) do
                local key = skill.perk .. skill.level
                if not seen[key] then
                    seen[key] = true
                    table.insert(rows, skill)
                    if not highest or skill.level > highest.level then
                        highest = skill
                    end
                end
            end
        end
    end
    return rows, highest
end

--- Which of the recipes `names` a character with `perk` (an id) at `level` and every other perk at
--- 0 has the AutoLearn skills of, as their scripts state them, marked true by name.
function T.autoLearnedAt(names, perk, level)
    local function meets(skill)
        return skill.level <= (skill.perk == perk and level or 0)
    end
    local earned = {}
    for _, name in ipairs(names) do
        local skills = autoLearnOf(name)
        for _, skill in ipairs(skills.any) do
            earned[name] = earned[name] or meets(skill)
        end
        if #skills.all > 0 then
            local all = true
            for _, skill in ipairs(skills.all) do
                all = all and meets(skill)
            end
            earned[name] = earned[name] or all
        end
    end
    return earned
end

--- Levels for T.levelUp and T.setLevelsQuietly: each perk of `rows` (T.autoLearnLevels) at 0 but
--- `perk`, which is at `level`.
function T.autoLearnLevelsWith(rows, perk, level)
    local levels = {}
    for _, row in ipairs(rows) do
        levels[row.perk] = 0
    end
    levels[perk] = level
    return levels
end

--- Registers a mod's two tests of learning the recipes `names` by skill level, named
--- `prefix .. "_learning_..."`:
--- - level_up_teaches_at_the_auto_learn_level: for each perk and level their AutoLearn skills name,
---   a character who knows none of them levels that perk up to that level, every other at 0, and
---   then knows exactly the recipes whose AutoLearn it meets, on both sides. Catches a recipe
---   taught a level early or never, or taught on one side only. `opts.timeoutSeconds` as a test's.
--- - joining_server_catches_up_earned_recipes (multiplayer, when `opts.catchUp` is given): a
---   character who reached the highest AutoLearn level before the mod was added joins, and
---   `opts.catchUp()` sends the request the client makes as it enters the world; the server, which
---   runs no check of its own on a join, teaches what that level earns and tells the client.
---   Catches a joining character left without recipes the server then refuses to use.
function T.autoLearnTests(prefix, names, opts)
    local what = "an AutoLearn skill on " .. table.concat(names, " or ")
    T.test(prefix .. "_learning_level_up_teaches_at_the_auto_learn_level", {
        timeoutSeconds = opts.timeoutSeconds,
        run = function(self)
            local rows = T.autoLearnLevels(names)
            if not T.need(self, #rows > 0, what) then return end
            self.rows, self.reads = rows, self.reads or {}
            for i, row in ipairs(rows) do
                -- Each row starts knowing none; the end of the test puts back what was known before.
                T.knowRecipes(self, names, false)
                T.levelUp(self, row.perk, T.autoLearnLevelsWith(rows, row.perk, row.level - 1))
                T.waitForKnown(self, names, T.autoLearnedAt(names, row.perk, row.level))
                T.step(function() self.reads[i] = { up = self.server["PZHarness.levelUp"] or {}, known = self.known } end)
            end
        end,
        validate = function(self)
            for i, row in ipairs(self.rows) do
                local result = self.reads[i] or {}
                local up = result.up or {}
                T.expectEqual(row.perk .. "'s level before", up.before, row.level - 1)
                T.expectEqual(row.perk .. "'s level after", up.after, row.level)
                self.known = result.known
                T.expectKnown(self, names, row.perk .. " " .. row.level, T.autoLearnedAt(names, row.perk, row.level))
            end
        end,
    })
    if not opts.catchUp then return end
    T.test(prefix .. "_learning_joining_server_catches_up_earned_recipes", {
        mpOnly = "single player has one copy of the character, which IsoWorld.init's own check covers",
        run = function(self)
            local rows, highest = T.autoLearnLevels(names)
            if not T.need(self, highest, what) then return end
            self.highest = highest
            T.knowRecipes(self, names, false)
            T.setLevelsQuietly(self, T.autoLearnLevelsWith(rows, highest.perk, highest.level), names)
            T.step(opts.catchUp)
            T.waitForKnown(self, names, T.autoLearnedAt(names, highest.perk, highest.level))
        end,
        validate = function(self)
            local before = self.server["PZHarness.setLevelsQuietly"] or {}
            local knewAny = not before.known
            for _, name in ipairs(names) do
                knewAny = knewAny or before.known[name] == true
            end
            T.expect(not knewAny, "setting the levels alone taught the server a recipe, so the catch-up is untested")
            local highest = self.highest
            T.expectKnown(self, names, "joining at " .. highest.perk .. " " .. highest.level,
                T.autoLearnedAt(names, highest.perk, highest.level))
        end,
    })
end
