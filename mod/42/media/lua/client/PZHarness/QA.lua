-- Development only, not published. The setup of a QA scenario (docs/adopting.md, "QA scenarios"):
-- a debug scenario for playing through the mod by hand, whose character nothing sees or hurts,
-- with every skill and recipe the mod reads, near what the mod's recipes and jobs take.

require "PZHarness/Runner"
require "PZHarness/TestCraft"
local Stage = require "PZHarness/Stage"
require "PZHarness/StageLots"

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

--- Every item script of the script module `module` by full type, sorted, so what is laid out or
--- checked from it comes out the same each run.
function QA.itemsOfModule(module)
    local found, items = {}, getScriptManager():getAllItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item:getModuleName() == module then
            table.insert(found, item:getFullName())
        end
    end
    table.sort(found)
    return found
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

--- A summary for QA.packToolboxes and QA.layGroups to count into, and QA.printSummary to print:
--- `tools` packed in `boxes` toolboxes, of the types `toolboxes` lists; `items` of `types` laid
--- in `groups`; and the types the game lacks (`unknown`) and those no square was left for
--- (`unplaced`).
function QA.newSummary()
    return { types = 0, items = 0, groups = 0, tools = 0, boxes = 0, toolboxes = {}, unknown = {}, unplaced = {} }
end

-- Kept tools go in vanilla toolboxes. A kept item goes in only if vanilla files it as a tool and it
-- fits a toolbox's MaxItemSize, which keeps the toolboxes few enough to hold: the crafting window
-- takes items only from the bags the character holds or wears (ISInventoryPage:refreshBackpacks).
local TOOLBOX = "Base.Toolbox"

--- Puts the kept vanilla tools of `stock` (a list of { type, used, kept }, as QA.materials gives)
--- in toolboxes in `player`'s inventory, starting a new one when the last has no room, the first
--- two in the hands, and counts them into `summary` (QA.newSummary). Room is counted with no
--- character, by the toolbox's own capacity, which the Organized and Disorganized traits would
--- change (ItemContainer.getEffectiveCapacity), so every character gets the same toolboxes. A kept
--- item that doesn't go in is added to its entry's `used`, what is left to lay out.
function QA.packToolboxes(player, stock, summary)
    local boxes, container = {}, nil
    local maxSize = instanceItem(TOOLBOX):getMaxItemSize()
    for _, entry in ipairs(stock) do
        local script = entry.kept > 0 and luautils.stringStarts(entry.type, "Base.") and getScriptManager():FindItem(entry.type)
        local category = script and script:getDisplayCategory()
        local weight = script and script:getActualWeight()
        if (category == "Tool" or category == "ToolWeapon") and weight < maxSize then
            for _ = 1, entry.kept do
                if not (container and container:hasRoomFor(nil, weight)) then
                    local box = player:getInventory():AddItem(instanceItem(TOOLBOX))
                    table.insert(boxes, box)
                    container = box:getItemContainer()
                end
                container:AddItem(QA.newItem(entry.type))
                summary.tools = summary.tools + 1
            end
            table.insert(summary.toolboxes, entry.type)
            entry.kept = 0
        end
        entry.used = entry.used + entry.kept
    end
    summary.boxes = #boxes
    player:setPrimaryHandItem(boxes[1])
    player:setSecondaryHandItem(boxes[2])
    -- So the inventory window shows the held toolboxes at once.
    ISInventoryPage.dirtyUI()
end

-- A layout of QA.layGroups: rows `width` squares wide from its origin, south one after the other,
-- skipping squares `accepts` refuses, so items keep their order around a house or a tree.
local Layout = {}
Layout.__index = Layout

--- The layout's next square `accepts` takes, cleared of ground cover so what lies there shows; nil
--- once the layout has taken `maxRows` rows.
function Layout:nextSquare()
    while self.row < self.maxRows do
        local square = getCell():getGridSquare(self.x + self.column, self.y + self.row, self.z)
        self.column = self.column + 1
        if self.column == self.width then
            self.column, self.row = 0, self.row + 1
        end
        if self.accepts(square) then
            Stage.clearGroundCover(square)
            return square
        end
    end
    return nil
end

--- Ends the row, and leaves the next empty, between groups.
function Layout:nextGroup()
    self.row = self.row + (self.column > 0 and 2 or 1)
    self.column = 0
end

--- The first square of the layout's next run of `length` squares east along the world that
--- `accepts` takes, with the layout moved past the run's other squares so nothing is laid on them;
--- nil if none is left.
function Layout:nextRun(length)
    local first
    repeat
        first = self:nextSquare()
    until not first or Stage.isAreaOpen(first, length, 1, self.accepts)
    for _ = 2, length do
        self:nextSquare()
    end
    return first
end

--- The west square of the layout's next whole row that `accepts` takes, past an empty row, with the
--- layout moved past that row; nil if none is left.
function Layout:nextOpenRow()
    self:nextGroup()
    while self.row < self.maxRows do
        local start = getCell():getGridSquare(self.x, self.y + self.row, self.z)
        self.row = self.row + 1
        if Stage.isAreaOpen(start, self.width, 1, self.accepts) then
            Stage.clearGroundCover(start)
            return start
        end
    end
    return nil
end

-- Lays `entry`'s items on the layout's next square, scattered over it so they show.
local function lay(layout, summary, entry, newItem)
    if not QA.isKnown(entry.type) then
        table.insert(summary.unknown, entry.type)
        return
    end
    local square = layout:nextSquare()
    if not square then
        table.insert(summary.unplaced, entry.type)
        return
    end
    for _ = 1, entry.count do
        square:AddWorldInventoryItem(newItem(entry), ZombRandFloat(0.2, 0.8), ZombRandFloat(0.2, 0.8), 0)
        summary.items = summary.items + 1
    end
    summary.types = summary.types + 1
end

local function isLoaded(square)
    return square ~= nil
end

local function newItemOf(entry)
    return QA.newItem(entry.type, entry.fluid)
end

--- Lays out `groups`, a list of { name, items }, in order from the square `origin` in rows `width`
--- squares wide running south, each group from a row of its own with an empty row before it, a
--- square to each item of `items`: { type, count, fluid }, `count` items of `type` filled with the
--- Fluid `fluid` if given. Counts into `summary` (QA.newSummary). `opts`:
--- - maxRows: the most rows the layout takes;
--- - accepts(square), if any: whether an item may lie on `square` (nil where none is loaded),
---   else any loaded square; the layout skips the others;
--- - after, if any: { [name] = fn(layout, summary) }, what a group sets after its items, with the
---   layout's nextSquare(), nextRun(length) and nextOpenRow(), and `width`; a group with no items
---   is laid only for this;
--- - newItem(entry), if any: the item to lay for `entry`, else QA.newItem(type, fluid).
function QA.layGroups(origin, width, groups, summary, opts)
    local after, newItem = opts.after or {}, opts.newItem or newItemOf
    local layout = setmetatable({ x = origin:getX(), y = origin:getY(), z = origin:getZ(), column = 0, row = 0,
        width = width, maxRows = opts.maxRows, accepts = opts.accepts or isLoaded }, Layout)
    local laid = 0
    for _, group in ipairs(groups) do
        if #group.items > 0 or after[group.name] then
            if laid > 0 then
                layout:nextGroup()
            end
            for _, entry in ipairs(group.items) do
                lay(layout, summary, entry, newItem)
            end
            if after[group.name] then
                after[group.name](layout, summary)
            end
            laid = laid + 1
        end
    end
    summary.groups = summary.groups + laid
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
