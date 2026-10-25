-- Development only, not published. The setup of a QA scenario (docs/adopting.md, "QA scenarios"):
-- a debug scenario for playing through the mod by hand, whose character nothing sees or hurts,
-- with every skill and recipe the mod reads, near what the mod's recipes and jobs take.

require "PZHarness/TestLib"

PZHarness = PZHarness or {}
local QA = {}
PZHarness.QA = QA

-- Every perk the `perks` test setting lists goes to this level: the top, so no recipe or job
-- refuses for want of skill.
QA.SKILL = 10

--- A debugScenarios entry named `name` that starts at `startLoc` and calls `setup(player)` on
--- its first tick. Its new save records the active mods and has no zombies, as the runner gives
--- the mod's own scenario (PZHarness.wrapSetSandbox): the scenario panel records no mods, and a
--- save without them loads without them.
function QA.scenario(name, startLoc, setup)
    local scenario = {
        name = name,
        startLoc = startLoc,
        -- onStart runs during the world's start (OnGameStart), before the global object systems
        -- exist, which clearing a square's ground cover or sowing reaches.
        onStart = function()
            local function onTick()
                Events.OnTick.Remove(onTick)
                setup(getPlayer())
            end
            Events.OnTick.Add(onTick)
        end,
    }
    PZHarness.wrapSetSandbox(scenario)
    return scenario
end

--- Teaches `player` every recipe of the mod, the build menu's too (PZHarness.Test.recipeNames and
--- buildRecipeNames). The craftRecipes reach a multiplayer server's copy as T.learnRecipes's do.
function QA.learnAllRecipes(player)
    PZHarness.Test.learnRecipes(player)
    PZHarness.Fixtures.learnRecipes(player, PZHarness.Test.buildRecipeNames())
end

--- Makes `player` a QA character: in god mode, invisible, carrying anything without tiring, with
--- every perk of the `perks` setting at QA.SKILL and every recipe of the mod (QA.learnAllRecipes).
function QA.setUpCharacter(player)
    player:setGodMod(true)
    player:setInvisible(true)
    player:setUnlimitedCarry(true)
    player:setUnlimitedEndurance(true)
    local levels = {}
    for _, perk in ipairs(PZHarness.testSettings.perks or {}) do
        levels[perk:getId()] = QA.SKILL
    end
    PZHarness.Fixtures.setPerkLevels(player, levels)
    QA.learnAllRecipes(player)
end

--- Whether the game has an item script named `fullType`.
function QA.isKnown(fullType)
    return getScriptManager():FindItem(fullType) ~= nil
end

--- A new item of `fullType`, its fluid container filled with the Fluid `fluid` if given; nil for
--- a type the game doesn't have.
function QA.newItem(fullType, fluid)
    local item = instanceItem(fullType)
    local container = item and fluid and item:getFluidContainer()
    if container then
        container:Empty()
        container:addFluid(fluid, container:getCapacity())
    end
    return item
end

--- Every craftRecipe and build menu recipe name of the mod (PZHarness.Test.recipeNames, then
--- buildRecipeNames).
function QA.modRecipeNames()
    local names = PZHarness.Test.recipeNames()
    for _, name in ipairs(PZHarness.Test.buildRecipeNames()) do
        table.insert(names, name)
    end
    return names
end

-- The Fluid an input draws from the item given for it, or nil.
local function drawnFluid(input)
    local drawn = input:hasConsumeFromItem() and input:getConsumeFromItemScript()
    if drawn and drawn:getResourceType() == ResourceType.Fluid and drawn:getPossibleInputFluids():size() > 0 then
        return drawn:getPossibleInputFluids():get(0)
    end
    return nil
end

--- What making each of the recipes `names` (craftRecipes or build menu recipes) once takes, a list
--- of { type, fluid, used, kept } by item type and the fluid it is filled with: `kept`, as many of
--- a kept tool as one recipe needs, and `used`, as many of what is used up as all of them
--- together. Each input is PZHarness.Test.inputItem's pick (with `prefer`), as many as
--- PZHarness.Test.inputCount gives, so a drainable counts by the uses it holds. Sorted by display
--- category, then type, so a layout of them comes out the same each run. Also returns the
--- inputs no item can meet, as "<recipe>: <line>".
function QA.materials(names, prefer)
    local scripts, needs, order, unmatched = getScriptManager(), {}, {}, {}
    for _, name in ipairs(names) do
        local recipe = scripts:getCraftRecipe(name) or scripts:getBuildableRecipe(name)
        local inputs = recipe:getInputs()
        for i = 0, inputs:size() - 1 do
            local input = inputs:get(i)
            if input:getResourceType() == ResourceType.Item then
                local item = PZHarness.Test.inputItem(input, prefer)
                if item then
                    local count, fluid = PZHarness.Test.inputCount(input, item), drawnFluid(input)
                    local key = item:getFullName() .. (fluid and "+" .. fluid:getFluidTypeString() or "")
                    local need = needs[key]
                    if not need then
                        need = { type = item:getFullName(), fluid = fluid, used = 0, kept = 0 }
                        needs[key] = need
                        table.insert(order, need)
                    end
                    if input:isKeep() then
                        need.kept = math.max(need.kept, count)
                    else
                        need.used = need.used + count
                    end
                else
                    table.insert(unmatched, name .. ": " .. input:getOriginalLine())
                end
            end
        end
    end
    table.sort(order, function(a, b)
        local ca = scripts:FindItem(a.type):getDisplayCategory() or ""
        local cb = scripts:FindItem(b.type):getDisplayCategory() or ""
        if ca ~= cb then return ca < cb end
        return a.type < b.type
    end)
    return order, unmatched
end

--- Builds the build menu entity of the tile `sprite` at x, y, z as `player` does from the build
--- menu (ISBuildIsoEntity:create, which ISBuildAction runs at the end of the job), turned as the
--- cursor's rotation `nSprite` turns it (ISBuildIsoEntity.nSprite: 1 is west), the build cheat
--- standing in for the materials and the job. Returns what is missing, or nil.
function QA.buildAsPlayer(player, sprite, nSprite, x, y, z)
    local info = SpriteConfigManager.getObjectInfoFromSprite(sprite)
    if not info then
        return "the build-menu entity of the tile " .. sprite
    end
    local build = ISBuildIsoEntity:new(player, info, nSprite, ISInventoryPaneContextMenu.getContainers(player))
    -- What the cursor sets before it builds: the player number, the squares it covers, and the
    -- facing from its rotation.
    build.player = player:getPlayerNum()
    build:ensureSquaresExist(x, y, z)
    local chosen = build:getSprite()
    local cheat = player:isBuildCheat()
    player:setBuildCheat(true)
    build.buildPanelLogic:startCraftAction(nil)
    build:create(x, y, z, build.north, chosen)
    player:setBuildCheat(cheat)
    if not PZHarness.Fixtures.objectWithSprite(getCell():getGridSquare(x, y, z), sprite) then
        return "the " .. info:getName() .. " built at " .. x .. "," .. y .. "," .. z
    end
    return nil
end

--- Prints `line` under `mark`, then a line under it for each of `summary`'s fields named in
--- `lists` that is a non-empty list ("<mark> <name>: a; b") or a string, what the setup couldn't
--- do.
function QA.printSummary(mark, line, summary, lists)
    print(mark .. " " .. line)
    for _, name in ipairs(lists) do
        local value = summary[name]
        if type(value) == "table" and #value > 0 then
            print(mark .. " " .. name .. ": " .. table.concat(value, "; "))
        elseif type(value) == "string" then
            print(mark .. " " .. name .. ": " .. value)
        end
    end
end

return QA
