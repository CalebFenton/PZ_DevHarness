require "PZHarness/TestWorld"
require "PZHarness/TestLearning"
local Runtime = require "PZHarness/TestRuntime"
local Report = require "PZHarness/Report"

-- Recipe inputs, crafting through the game's menus, and diagnostics for refused/dropped crafts.
local T = PZHarness.Test

--- The vanilla items an input naming several takes when the caller's `prefer` names none of
--- them: for a tag, the first possible item can differ from run to run, and the tests, the QA
--- layouts and the promo's recipe sheets must come out the same each run.
T.VANILLA_PREFERRED = {
    "Base.Bucket", "Base.WaterBottle", "Base.Charcoal", "Base.HandDrill", "Base.Screwdriver", "Base.Wrench",
    "Base.PipeWrench", "Base.BlowTorch", "Base.Hammer", "Base.SmithingHammer", "Base.Saw", "Base.KitchenKnife",
    "Base.Pliers", "Base.Tongs", "Base.WeldingMask", "Base.Shovel2", "Base.MasonsTrowel", "Base.Matches",
    "Base.BucketConcreteFull",
}

-- The first of `possible` (an ArrayList of script Items) named in `wanted`, or nil.
local function firstWanted(possible, wanted)
    for _, fullType in ipairs(wanted) do
        for j = 0, possible:size() - 1 do
            if possible:get(j):getFullName() == fullType then
                return possible:get(j)
            end
        end
    end
    return nil
end

--- The script Item the harness gives for `input`, a recipe's InputScript, or nil when it has no
--- possible item: the first of its possible items listed in `prefer` (full names), else in
--- T.VANILLA_PREFERRED, else its first possible item other than a generic Base.Moveable, else its
--- first.
function T.inputItem(input, prefer)
    local possible = input:getPossibleInputItems()
    local chosen = firstWanted(possible, prefer or {}) or firstWanted(possible, T.VANILLA_PREFERRED)
    if chosen then
        return chosen
    end
    for j = 0, possible:size() - 1 do
        if possible:get(j):getFullName() ~= "Base.Moveable" then
            return possible:get(j)
        end
    end
    return possible:size() > 0 and possible:get(0) or nil
end

--- How many of the script Item `item` (T.inputItem's pick) cover one craft's `input`: a drainable
--- input that counts uses takes as many full items as its uses need, two sand bags for eight uses;
--- any other input its amount. A line naming its own amount for some items (`item 10 [2:Base.Scrap;
--- Base.Nails]`) asks that many of each and reads 1 as a whole (InputScript.Load); an item the
--- line doesn't list reads 1 alone (InputScript.getAmount), so the larger of the two is the count.
function T.inputCount(input, item)
    local amount = math.max(input:getIntAmount(item:getFullName()), input:getIntAmount())
    if item:isItemType(ItemType.DRAINABLE) and not input:isItemCount() then
        -- The nudge keeps a use delta stored a hair over 1/n from losing its last use to rounding.
        local perItem = math.floor(1 / item:getUseDelta() + 0.0001)
        return math.ceil(amount / perItem)
    end
    return amount
end

--- What one craft of `recipe` takes, tools included, as T.give items: each input gets
--- T.inputItem's choice, T.inputCount of it. Also returns the inputs that had no possible item at
--- all.
function T.recipeInputs(recipe, prefer)
    local items, unmatched = {}, {}
    local inputs = recipe:getInputs()
    for i = 0, inputs:size() - 1 do
        local input = inputs:get(i)
        local item = T.inputItem(input, prefer)
        if item then
            table.insert(items, { type = item:getFullName(), count = T.inputCount(input, item) })
        else
            table.insert(unmatched, input:getOriginalLine())
        end
    end
    return items, unmatched
end

--- AnySurfaceCraft recipes need a table the character can walk to. Puts one on a free square next
--- to the character, with no wall in between, unless one is there already
--- (PZHarness.Fixtures.placeWorkTable). Not undone: scenarios call it too, and a table left
--- standing harms no later test. In multiplayer the server places it, since one placed here would
--- exist on this client only, and a queued wait lasts until this client has it. Without a free
--- square it prints a FAIL line of its own, as a failed server call outside a test does.
function T.placeWorkTable(player)
    if PZHarness.Fixtures.workTableNear(player) then
        return
    end
    if not isClient() then
        if not PZHarness.Fixtures.placeWorkTable(player) then
            Report.lateFailure("PZHarness.workTable", "no free square next to the character for a work table")
        end
        return
    end
    Runtime.outside("PZHarness.workTable", {}, function(at)
        local square = getSquare(at.x, at.y, at.z)
        return T.objectWithSprite(square, PZHarness.Fixtures.WORK_TABLE_SPRITE) ~= nil
    end)
end

-- Crafting

-- The crafting logic the game starts `recipe` from the item `from` with: the right-click menu's,
-- with a table in reach as the surface, or with `bench` (T.placeBench's) the bench window's.
local function craftLogic(recipe, from, bench)
    local p = T.player()
    local logic
    if bench then
        logic = HandcraftLogic.new(p, bench:getComponent(ComponentType.CraftBench), bench)
    else
        logic = HandcraftLogic.new(p, nil, nil)
        logic:setIsoObject(logic:findCraftSurface(p, 2))
    end
    -- A player's right-click comes after the UI has drawn, by when the inventory windows list the
    -- containers around where the character is now and faces; at the uncapped frame rate a test
    -- can get here first.
    T.refreshInventoryWindows()
    logic:setContainers(ISInventoryPaneContextMenu.getContainers(p))
    logic:setRecipeFromContextClick(recipe, from)
    return logic
end

-- Why the game would refuse to start this craft, or nil if it would start it. The menu and the
-- crafting windows refuse without saying why.
function T.craftRefusal(recipe, from, bench)
    local p = T.player()
    local logic = craftLogic(recipe, from, bench)
    if logic:canPerformCurrentRecipe() then
        return nil
    elseif not p:isRecipeActuallyKnown(recipe) then
        return "recipe not known"
    elseif not recipe:characterHasRequiredSkills(p) then
        return "skills too low"
    elseif recipe:isAnySurfaceCraft() and not logic:isCharacterInRangeOfWorkbench() then
        return "no table in reach"
    elseif p:tooDarkToRead() then
        return "too dark"
    end
    local missing = {}
    local inputs = recipe:getInputs()
    for i = 0, inputs:size() - 1 do
        local data = logic:getRecipeData():getDataForInputScript(inputs:get(i))
        if data and not data:isInputItemsSatisfied() then
            table.insert(missing, inputs:get(i):getOriginalLine())
        end
    end
    return "missing " .. table.concat(missing, "; ")
end

local function addRefusal(self, recipe, reason)
    self.refusal = (self.refusal and self.refusal .. "; " or "") .. recipe:getName() .. ": " .. reason
end

-- What stops a craft at perform, where the game checks the recipe again and gives up without a
-- word (HandcraftLogic.performCurrentRecipe, CraftRecipeData.perform): the start's check doesn't
-- look at the reach of the containers, and the rest can change while the craft is queued.
local function performProblems(action, recipe)
    local p, problems = action.character, {}
    if not p:isRecipeActuallyKnown(recipe) then
        table.insert(problems, "recipe not known")
    end
    if not recipe:characterHasRequiredSkills(p) then
        table.insert(problems, "skills too low")
    end
    if not recipe:canBeDoneInDark() and p:tooDarkToRead() then
        table.insert(problems, "too dark")
    end
    local containers = action.logic and action.containers
    for i = 0, (containers and containers:size() or 0) - 1 do
        local container = containers:get(i)
        local one = ArrayList.new()
        one:add(container)
        if not action.logic:isContainersAccessible(one) then
            local outer = container:getOutermostContainer()
            local part, square = outer:getVehiclePart(), outer:getSquare()
            table.insert(problems, "the " .. tostring(container:getType()) .. " container out of reach"
                .. (part and " (vehicle part " .. part:getId() .. ")" or "")
                .. (square and string.format(" at %d,%d", square:getX(), square:getY()) or ""))
        end
    end
    return problems
end

-- Watches the crafts `start()` queues, so that one the game queued and then dropped says whether
-- it never performed or what was wrong when it did.
local function watchCrafts(self, recipe, start)
    local queue = ISTimedActionQueue.getTimedActionQueue(T.player()).queue
    local queued = {}
    for _, action in ipairs(queue) do
        queued[action] = true
    end
    start()
    for _, action in ipairs(queue) do
        if not queued[action] and action.Type == "ISHandcraftAction" then
            local perform = action.perform
            function action.perform(a)
                a.harnessPerformed = true
                local problems = performProblems(a, recipe)
                if #problems > 0 then
                    addRefusal(self, recipe, "at perform, " .. table.concat(problems, ", "))
                end
                return perform(a)
            end
            T.step(function()
                if not action.harnessPerformed then
                    addRefusal(self, recipe, "queued but never performed")
                end
            end)
        end
    end
end

--- Starts crafting `recipe` from the item `from` the way the right-click menu does or, with
--- `bench` (T.placeBench's), the way the bench's crafting window does. Adds why the game refused
--- to `self.refusal`, which the test's failures then end with.
function T.startCraft(self, recipe, from, bench)
    local refusal = T.craftRefusal(recipe, from, bench)
    if refusal then
        addRefusal(self, recipe, refusal)
    end
    watchCrafts(self, recipe, function()
        if bench then
            ISEntityUI.HandcraftStart(T.player(), craftLogic(recipe, from, bench), false, true)
        else
            ISInventoryPaneContextMenu.OnNewCraft(from, recipe, T.player():getPlayerNum(), false)
        end
    end)
end

-- The queued operation behind both entry points. Registered tests keep their all-recipe learning,
-- minimum skills and deferred setup; a craft within a larger test knows only its target and runs
-- ready now, so its queued input changes precede the native actions.
local function craft(self, name, from, counted, opts, registered)
    opts = opts or {}
    local p = T.player()
    local recipe = T.need(self, getScriptManager():getCraftRecipe(name), "the recipe " .. name)
    if not recipe then return false end
    if registered then
        -- Scenario setup may already know them; otherwise learning belongs to this test.
        local names = T.recipeNames()
        for _, recipeName in ipairs(names) do
            if not p:isRecipeActuallyKnown(recipeName) then
                T.knowRecipes(self, names, true)
                break
            end
        end
    else
        T.knowRecipes(self, { name }, true)
    end
    if registered or opts.workTable then T.placeWorkTable(p) end
    if not registered then T.setRecipeSkills(self, recipe) end
    local bench = opts.bench and T.placeBench(self, opts.bench[1], opts.bench[2])
    if opts.bench and not bench then return false end
    if registered and opts.prepare then
        opts.prepare(self, recipe)
    else
        if registered then T.setRecipeSkills(self, recipe, true) end
        local inputs, unmatched = T.recipeInputs(recipe, opts.prefer)
        if not T.need(self, #unmatched == 0, "an item for " .. table.concat(unmatched, "; ")) then return false end
        T.give(self, "inputs", inputs)
    end
    local function queueCraft()
        if registered then
            if opts.setup then opts.setup(self) end
            -- Registered tests retain the native refusal diagnostic if the light never settles.
            Runtime.waitForLight(true)
        else
            T.waitForLight(self)
        end
        T.step(function()
            local item = T.need(self, p:getInventory():getFirstTypeRecurse(from), "a " .. from .. " to craft from")
            if not item then return end
            T.startCraft(self, recipe, item, bench and bench.object)
            -- Added in this step after the native actions, before any caller's later reads.
            T.count(self, "craft", counted, { dropped = not registered or opts.dropped ~= false })
            if registered and opts.after then
                T.step(function() opts.after(self) end)
            end
        end)
    end
    if registered then
        T.step(queueCraft)
    else
        if opts.ready then opts.ready(self) end
        queueCraft()
    end
    return true
end

--- Queues crafting `name` from the first carried `from` (full type), then counts `counted` types
--- into self.counts.craft, including dropped outputs. Returns whether preparation queued the
--- craft, not whether the game will accept it. Knows only this recipe until the test ends, sets
--- its exact required skills, and gives one craft's inputs (T.recipeInputs with `opts.prefer`).
--- `opts.workTable` ensures a nearby table; `opts.bench` is { entity script, sprite } (T.placeBench).
--- `opts.ready(self)` runs now to queue input changes, before waiting for light and crafting.
function T.craft(self, name, from, counted, opts)
    return craft(self, name, from, counted, opts, false)
end

--- Registers a test around the queued craft operation, instantly unless `spec.instant` is false.
--- Crafts `spec.recipe` from the first `spec.from` via the right-click menu or `spec.bench`'s
--- window. Knows all the mod's recipes until the test ends, ensures a table, and by default raises
--- skills to at least the requirements and gives T.recipeInputs with `spec.prefer` into self.items.inputs.
--- `spec.prepare(self, recipe)` replaces only that skill/input preparation; `spec.setup(self)`
--- runs once its queued preparation has finished and may queue more changes before the craft.
--- Counts into self.counts.craft, including dropped items unless `spec.dropped` is false, then
--- runs `spec.after(self)` in a step for further reads. validate expects `spec.counts` and, with
--- `spec.refused`, a refusal, then runs `spec.validate(self)`. Failures include craft diagnostics.
function T.craftTest(name, spec)
    local counted = {}
    for fullType in pairs(spec.counts or {}) do
        table.insert(counted, fullType)
    end
    T.test(name, {
        sandbox = spec.sandbox,
        hour = spec.hour,
        instant = spec.instant ~= false,
        spOnly = spec.spOnly,
        mpOnly = spec.mpOnly,
        run = function(self)
            craft(self, spec.recipe, spec.from, counted, spec, true)
        end,
        validate = function(self)
            local counts = self.counts.craft or {}
            for fullType, count in pairs(spec.counts or {}) do
                T.expectEqual(fullType, counts[fullType], count)
            end
            if spec.refused then
                T.expect(self.refusal ~= nil, "the game would start the craft")
            end
            if spec.validate then
                spec.validate(self)
            end
        end,
    })
end

