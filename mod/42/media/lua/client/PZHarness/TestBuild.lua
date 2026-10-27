require "PZHarness/TestCraft"
require "PZHarness/StageLots"
local Stage = require "PZHarness/Stage"

-- Building from the build menu in a test: the entry of a game entity, its cursor's test of a
-- square, and a build through the menu's own path (ISBuildIsoEntity, ISBuildAction). The build
-- objects are server Lua, which loads after client Lua, so they are reached at call time.

local T = PZHarness.Test

-- How far round a build site T.buildSite keeps open ground: the character stands beside the site,
-- and the containers the build menu offers reach one square further (ISInventoryPage's loot
-- window, 3 by 3 round the character).
local SITE_CLEARANCE = 2

-- Whether `square` and every square within SITE_CLEARANCE of it are open ground.
local function isClearAround(square)
    local corner = getSquare(square:getX() - SITE_CLEARANCE, square:getY() - SITE_CLEARANCE, square:getZ())
    local side = 2 * SITE_CLEARANCE + 1
    return Stage.isAreaOpen(corner, side, side, Stage.isOpenGround)
end

--- A square for T.build, nearest the character, or nil and missing one: bare outdoor ground
--- (T.squares), as grass and the like block placing anything built (BlocksPlacement), with open
--- ground all round it (Stage.isOpenGround) as far as the build menu reaches. No container but
--- what the character carries is then in the build's reach, and no wall shades the site or turns
--- the walk beside it.
function T.buildSite(self)
    local found = T.squares(self, 1, { bare = true, accept = isClearAround })
    T.need(self, found, "a build site: bare outdoor ground with open ground round it")
    return found and found[1]
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
    return "its inputs"
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
-- before the cursor can build (ISBuildPanel): with the containers the build menu offers, and the
-- player number the drag sets (IsoCell.setDrag).
local function newBuild(info)
    local player = T.player()
    local build = ISBuildIsoEntity:new(player, info, 1, ISInventoryPaneContextMenu.getContainers(player))
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

--- Queues building the build menu's entry of `entity` on `square`, a T.buildSite, through the
--- menu's own path: the character knows the recipe and has its skill levels (both until the test
--- ends), carries exactly its inputs (T.recipeInputs with `prefer`: enough full drainables for an
--- input's uses), stands next to the square on both sides (T.goNextTo) once it is light there
--- (T.waitForLight), and builds; then the build waits until `arrived()` holds on this client, else
--- misses `what`. A build the menu refuses, for its inputs or its square, is missing at once. What
--- the build leaves on the square goes when the test ends (T.trackSquare). Returns the build, or
--- nil; once it has run, its `face` is the face it built (its upper-case name).
function T.build(self, entity, square, prefer, arrived, what)
    local info = T.need(self, T.buildEntry(entity), "the build menu entry of " .. entity)
    local recipe = info and info:getRecipe() and info:getRecipe():getCraftRecipe()
    if not T.need(self, recipe, "the build recipe of " .. entity) then return nil end
    local inputs, unmatched = T.recipeInputs(recipe, prefer)
    if not T.need(self, #unmatched == 0, "an item for " .. table.concat(unmatched, "; ")) then return nil end
    local result = {}
    T.trackSquare(self, square)
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
