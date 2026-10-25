require "PZHarness/TestLib"
require "PZHarness/TestLearning"

-- Building from the build menu in a test: the entry of a game entity, its cursor's test of a
-- square, and a build through the menu's own path (ISBuildIsoEntity, ISBuildAction). The build
-- objects are server Lua, which loads after client Lua, so they are reached at call time.

local T = PZHarness.Test

--- Sets the character's skills to the levels `recipe` requires, until the test ends (T.setPerk).
function T.setRecipeSkills(self, recipe)
    for i = 0, recipe:getRequiredSkillCount() - 1 do
        local skill = recipe:getRequiredSkill(i)
        T.setPerk(self, skill:getPerk(), skill:getLevel())
    end
end

-- Why the build menu refuses `recipe` to the character, checked in the game's order
-- (CraftRecipeManager.isValidRecipeForCharacter, then CraftRecipeData.canPerform): the recipe
-- unknown, a skill short, the dark, else the inputs.
local function refusal(recipe)
    local player = T.player()
    if recipe:needToBeLearn() and not player:isRecipeKnown(recipe, true) then
        return "the recipe " .. recipe:getName() .. " unknown"
    end
    for i = 0, recipe:getRequiredSkillCount() - 1 do
        local skill = recipe:getRequiredSkill(i)
        local level = player:getPerkLevel(skill:getPerk())
        if level < skill:getLevel() then
            return tostring(skill:getPerk()) .. " at " .. level .. ", under " .. skill:getLevel()
        end
    end
    if player:tooDarkToRead() then
        return "the dark"
    end
    return "its inputs among what the character carries"
end

--- The build menu entry of `entity` (a game entity script's full name), or nil.
function T.buildEntry(entity)
    local script = getScriptManager():getGameEntityScript(entity)
    local spriteConfig = script and script:getComponentScriptFor(ComponentType.SpriteConfig)
    if not spriteConfig then
        return nil
    end
    local infos = SpriteConfigManager.GetObjectInfoList()
    for i = 0, infos:size() - 1 do
        if infos:get(i):getScript() == spriteConfig then
            return infos:get(i)
        end
    end
    return nil
end

-- A build cursor of the entry `info` for this client's character, as the build panel makes one
-- before the cursor can build (ISBuildPanel): with the player number the drag sets
-- (IsoCell.setDrag), and offered only the containers the character carries, those its inventory
-- window shows. A test gives the character what it builds from, and a container in the world that
-- is in reach when the cursor is made can be out of it once the build has walked the character
-- beside the site, which refuses the whole build (BaseCraftingLogic.isContainersAccessible).
local function newBuild(info)
    local player = T.player()
    local carried = ArrayList.new()
    for _, button in ipairs(getPlayerInventory(player:getPlayerNum()).inventoryPane.inventoryPage.backpacks) do
        carried:add(button.inventory)
    end
    local build = ISBuildIsoEntity:new(player, info, 1, carried)
    build.player = player:getPlayerNum()
    return build
end

--- Whether the build cursor of `entity` would take `square`: the cursor's own test
--- (ISBuildIsoEntity:isValid) of each square its face covers, the entity's OnIsValid among it. The
--- recipe's inputs don't count, but a hammer among its tools must be carried (haveMaterial). Nil
--- without the build menu entry.
function T.placeable(entity, square)
    local info = T.buildEntry(entity)
    if not info then return nil end
    return newBuild(info):isValid(square)
end

--- Queues building the build menu's entry of `entity` on `square` through the menu's own path:
--- the character knows the recipe and has its skill levels (both until the test ends), carries
--- exactly its inputs (T.recipeInputs with `prefer`: enough full drainables for an input's
--- uses), stands next to the square on both sides (T.goNextTo) once it is light there
--- (T.waitForLight), and builds from what it carries alone; then the build waits until
--- `arrived()` holds on this client, else misses `what`. A build the menu refuses, for its inputs
--- or its square, is missing at once.
--- A mod that tracks what the build leaves, for removal when the test ends, queues its handler
--- before this. Returns the build, or nil: `types` the full types of its inputs, `expected` what it
--- should leave carried of them (T.expectBuildUsed), and once it has run `face` the face it built
--- (its upper-case name).
function T.build(self, entity, square, prefer, arrived, what)
    local info = T.need(self, T.buildEntry(entity), "the build menu entry of " .. entity)
    local recipe = info and info:getRecipe() and info:getRecipe():getCraftRecipe()
    if not T.need(self, recipe, "the build recipe of " .. entity) then return nil end
    local inputs, unmatched = T.recipeInputs(recipe, prefer)
    if not T.need(self, #unmatched == 0, "an item for " .. table.concat(unmatched, "; ")) then return nil end
    -- What a build should leave carried: its kept tools, and none of the items it takes whole.
    -- A drainable it takes uses of stays part-used, so isn't counted.
    local result = { expected = {}, types = {} }
    for i, entry in ipairs(inputs) do
        local input = recipe:getInputs():get(i - 1)
        if input:isKeep() then
            result.expected[entry.type] = entry.count
        elseif input:isItemCount() or not getScriptManager():FindItem(entry.type):isItemType(ItemType.DRAINABLE) then
            result.expected[entry.type] = 0
        end
        table.insert(result.types, entry.type)
    end
    T.knowRecipes(self, { recipe:getName() })
    T.setRecipeSkills(self, recipe)
    T.give(self, "materials", inputs)
    -- Stands first: the character's current square follows a teleport only on its next update, and
    -- the cursor walks a character it can't see beside the site (luautils.walkAdjSquares).
    T.goNextTo(self, square)
    -- The game refuses a build in the dark (CraftRecipeData.canPerform).
    T.waitForLight(self)
    T.step(function()
        local build = newBuild(info)
        -- The build panel's own picking of the recipe's inputs from what is carried.
        build.buildPanelLogic:refresh()
        build.buildPanelLogic:autoPopulateInputs()
        local refused = not build.buildPanelLogic:canPerformCurrentRecipe() and refusal(recipe)
        if T.need(self, not refused, "the build menu building " .. entity .. (refused and ", refused for " .. refused or ""))
            and T.need(self, build:isValid(square), "the build menu taking " .. entity .. "'s square") then
            result.face = string.upper(build:getFace():getFaceName())
            build:tryBuild(square:getX(), square:getY(), square:getZ())
        end
    end)
    T.waitFor(self, arrived, what)
    return result
end

--- Expects T.build's `build` to have taken what it takes while keeping its tools, by `left`
--- (T.count's counts of its `types` once it built).
function T.expectBuildUsed(build, left)
    for fullType, count in pairs(build and build.expected or {}) do
        local carried = left and left[fullType] or 0
        T.expect(carried == count, "building left " .. carried .. " " .. fullType .. ", not " .. count)
    end
end
