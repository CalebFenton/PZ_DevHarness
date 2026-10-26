require "PZHarness/TestWorld"
require "PZHarness/TestLearning"
local Runtime = require "PZHarness/TestRuntime"

-- Recipe inputs, crafting through the game's menus, and diagnostics for refused/dropped crafts.
local T = PZHarness.Test

--- The script Item the harness gives for `input`, a recipe's InputScript, or nil when it has no
--- possible item: the first of its possible items listed in `prefer` (full names), else its first
--- possible item other than a generic Base.Moveable, else its first.
function T.inputItem(input, prefer)
    local possible = input:getPossibleInputItems()
    for _, wanted in ipairs(prefer or {}) do
        for j = 0, possible:size() - 1 do
            if possible:get(j):getFullName() == wanted then
                return possible:get(j)
            end
        end
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

--- Adds T.recipeInputs to this game's inventory at once; returns the inputs that had no possible
--- item. A multiplayer server doesn't get them: give them with T.give instead.
function T.addRecipeInputs(player, recipe, prefer)
    local items, unmatched = T.recipeInputs(recipe, prefer)
    for _, item in ipairs(items) do
        player:getInventory():AddItems(item.type, item.count)
    end
    return unmatched
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
            print(PZHarness.run.tag .. " FAIL PZHarness.workTable: no free square next to the character for a work table")
            PZHarness.ServerCalls.lateFailures = PZHarness.ServerCalls.lateFailures + 1
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
-- with a table in reach as the surface, or with `bench` (from T.bench) the bench window's.
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
    PZHarness.refreshInventoryWindows()
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
--- `bench` (from T.bench), the way the bench's crafting window does. Adds why the game refused
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

--- Registers a test that crafts `spec.recipe` from the first `spec.from` item via the right-click
--- menu or, with `spec.bench` ({ entity script, sprite }, see T.bench), via that workstation's
--- window; instantly unless `spec.instant` is false. The character knows the mod's recipes, has the
--- required levels, stands by a table and carries exactly one craft's inputs (T.recipeInputs with
--- `spec.prefer`, copies in `self.items.inputs`) plus what `spec.setup(self)` adds. validate()
--- expects `spec.counts` in the server copy's inventory or at its feet (T.count into
--- `self.counts.craft`), and when `spec.refused` the game refusing the craft, then runs
--- `spec.validate(self)`; `spec.after(self)` may queue more reads before that. A failing test also
--- reports why the game refused the craft.
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
            local p = T.player()
            local recipe = T.need(self, getScriptManager():getCraftRecipe(spec.recipe), "the recipe " .. spec.recipe)
            if not recipe then return end
            -- Once the first craft test has taught them all, learning them again would only cost
            -- a multiplayer client a server round trip.
            for _, name in ipairs(T.recipeNames()) do
                if not p:isRecipeActuallyKnown(name) then
                    T.learnRecipes(p)
                    break
                end
            end
            T.placeWorkTable(p)
            local bench = spec.bench and T.placeBench(self, spec.bench[1], spec.bench[2])
            if spec.bench and not bench then return end
            -- Set on both sides even when this client's copy has the level already: it may be a
            -- perk sync ahead of the server's, which refuses the craft at perform without a word
            -- (CraftRecipeManager.isValidRecipeForCharacter) while this client's action completes.
            for i = 0, recipe:getRequiredSkillCount() - 1 do
                local skill = recipe:getRequiredSkill(i)
                T.setPerk(self, skill:getPerk(), math.max(p:getPerkLevel(skill:getPerk()), skill:getLevel()))
            end
            local inputs, unmatched = T.recipeInputs(recipe, spec.prefer)
            if not T.need(self, #unmatched == 0, "an item for " .. table.concat(unmatched, "; ")) then return end
            T.give(self, "inputs", inputs)
            T.step(function()
                if spec.setup then
                    spec.setup(self)
                end
                -- The light can still lag the clock the previous test put back, and the game
                -- refuses a craft in the dark; the test is about the craft, not the dusk.
                Runtime.waitForLight(true)
                T.step(function()
                    local from = T.need(self, p:getInventory():getFirstTypeRecurse(spec.from), "a " .. spec.from .. " to craft from")
                    if not from then return end
                    T.startCraft(self, recipe, from, bench and bench.object)
                    -- Queued after the craft's actions, which T.startCraft has just queued.
                    T.count(self, "craft", counted, { dropped = true })
                    if spec.after then
                        T.step(function() spec.after(self) end)
                    end
                end)
            end)
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

