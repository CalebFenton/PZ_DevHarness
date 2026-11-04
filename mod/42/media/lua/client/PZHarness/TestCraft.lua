require "PZHarness/TestWorld"
require "PZHarness/TestLearning"
local Runtime = require "PZHarness/TestRuntime"
local Report = require "PZHarness/Report"

-- Recipe inputs, crafting through the game's menus, several crafts in turn in one test, and
-- diagnostics for refused/dropped crafts.
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
        return PZHarness.Fixtures.objectWithSprite(square, PZHarness.Fixtures.WORK_TABLE_SPRITE) ~= nil
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

--- The input line of `recipe` that takes `fullType`: the definition of its first input that does
--- (InputScript.getOriginalLine), or nil.
function T.inputLineFor(recipe, fullType)
    local item, inputs = getScriptManager():getItem(fullType), recipe:getInputs()
    for i = 0, inputs:size() - 1 do
        if item and inputs:get(i):containsItem(item) then
            return inputs:get(i):getOriginalLine()
        end
    end
    return nil
end

--- T.craftRefusal's reason when `recipe`'s OnTest turns down the `fullType` given for the input
--- that takes it: "OnTest turned down <that input's line>".
function T.onTestRefusal(recipe, fullType)
    return "OnTest turned down " .. tostring(T.inputLineFor(recipe, fullType))
end

-- Whether `containers` (an ArrayList of ItemContainers) hold items of a type `input` takes and
-- `recipe`'s OnTest turns every one of them down. The game asks OnTest of each such item before
-- its other tests (CraftRecipeManager.consumeInputItemInternal), and an input it gets no item for
-- reads as unsatisfied, as a missing one does.
local function turnedDown(recipe, input, containers)
    local p, found = T.player(), false
    for i = 0, containers:size() - 1 do
        local items = containers:get(i):getItems()
        for j = 0, items:size() - 1 do
            local item = items:get(j)
            local script = item:getScriptItem()
            if script and input:containsItem(script) then
                if recipe:OnTestItem(item, p) then
                    return false
                end
                found = true
            end
        end
    end
    return found
end

--- Why the game would refuse to start this craft, or nil if it would start it. The menu and the
--- crafting windows refuse without saying why. In the game's order: "recipe not known", "skills
--- too low", "no table in reach", "too dark", else each input left unsatisfied, joined by "; ":
--- T.onTestRefusal's reason where the recipe's OnTest turned down every item there for it, else
--- "missing <its line>".
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
    local reasons, containers = {}, ISInventoryPaneContextMenu.getContainers(p)
    local inputs = recipe:getInputs()
    for i = 0, inputs:size() - 1 do
        local input = inputs:get(i)
        local data = logic:getRecipeData():getDataForInputScript(input)
        if data and not data:isInputItemsSatisfied() then
            local line = input:getOriginalLine()
            table.insert(reasons, turnedDown(recipe, input, containers) and "OnTest turned down " .. line or "missing " .. line)
        end
    end
    return #reasons > 0 and table.concat(reasons, "; ") or "refused with every input satisfied"
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

-- What `self.refusal` holds when the game refuses `recipe` for `refused` alone: T.craftRefusal's
-- reason (a string, such as "skills too low"), or `{ onTest = fullType }`, the recipe's OnTest
-- turning down the `fullType` given for the input that takes it (T.onTestRefusal). Nil for
-- anything else, `true` among it, which would pass on any refusal.
local function refusalOf(recipe, refused)
    if type(refused) == "string" then
        return recipe:getName() .. ": " .. refused
    elseif type(refused) == "table" and refused.onTest then
        return recipe:getName() .. ": " .. T.onTestRefusal(recipe, refused.onTest)
    end
    return nil
end

--- Registers a test around the queued craft operation, instantly unless `spec.instant` is false.
--- Crafts `spec.recipe` from the first `spec.from` via the right-click menu or `spec.bench`'s
--- window. Knows all the mod's recipes until the test ends, ensures a table, and by default raises
--- skills to at least the requirements and gives T.recipeInputs with `spec.prefer` into self.items.inputs.
--- `spec.prepare(self, recipe)` replaces only that skill/input preparation; `spec.setup(self)`
--- runs once its queued preparation has finished and may queue more changes before the craft.
--- Counts into self.counts.craft, including dropped items unless `spec.dropped` is false, then
--- runs `spec.after(self)` in a step for further reads. validate expects `spec.counts` and, with
--- `spec.refused`, the game's refusal for that reason alone (see refusalOf), then runs
--- `spec.validate(self)`. Failures include craft diagnostics.
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
                local recipe = getScriptManager():getCraftRecipe(spec.recipe)
                local expected = recipe and refusalOf(recipe, spec.refused)
                if T.expect(expected ~= nil, "spec.refused names no reason: give T.craftRefusal's, or { onTest = <full type> }") then
                    T.expectEqual("why the game refused", self.refusal, expected)
                end
            end
            if spec.validate then
                spec.validate(self)
            end
        end,
    })
end

-- Crafting in turn: one test crafting several times

--- Queues knowing the recipes `names` until the test ends, the highest level each skill they
--- require (T.setPerk), and a table in reach: a test that crafts them in turn (T.craftFrom) pays
--- the setup of one craft test however many it crafts. Returns the CraftRecipes by name, or nil
--- when a name doesn't resolve, which the test then misses.
function T.readyToCraft(self, names)
    local recipes, levels = {}, {}
    for _, name in ipairs(names) do
        local recipe = T.need(self, getScriptManager():getCraftRecipe(name), "the recipe " .. name)
        if not recipe then return nil end
        recipes[name] = recipe
        for i = 0, recipe:getRequiredSkillCount() - 1 do
            local skill = recipe:getRequiredSkill(i)
            levels[skill:getPerk()] = math.max(levels[skill:getPerk()] or 0, skill:getLevel())
        end
    end
    T.knowRecipes(self, names)
    T.placeWorkTable(T.player())
    for perk, level in pairs(levels) do
        T.setPerk(self, perk, level)
    end
    return recipes
end

-- `items` (T.give items) less one of `fullType`.
local function withoutOne(items, fullType)
    for i, item in ipairs(items) do
        if item.type == fullType then
            item.count = item.count - 1
            if item.count == 0 then
                table.remove(items, i)
            end
            return
        end
    end
end

--- Queues one craft of the CraftRecipe `recipe` (T.readyToCraft's) from `from`: a T.give item
--- ({ type, condition, repaired, uses, modData }) given for it, or the full type of one the
--- character already carries, such as an earlier craft's output. The rest of one craft's inputs
--- come with it (T.recipeInputs, preferring `from`'s type, then `opts.prefer`); `opts.inputs(items)`
--- may change that list before it is given, and `opts.setup(self)` queues what else the craft needs,
--- such as water in a bottle. Afterwards it reads the authority's items of `from`'s type and of
--- `opts.read` (T.readCarried, under `result.label`), and waits until this client's copy of `from`,
--- which the inventory and its tooltip show, matches the authority's. The `from` left is taken away
--- then, so that a later craft can't pick it. Returns `result`, filled in as the queue runs:
--- `label`, `item`, the authority's `from` (T.carriedItems' entry, nil once the craft used it up),
--- and `refusal`, why the game wouldn't start the craft ("<recipe>: <T.craftRefusal's reason>", nil
--- if it started), kept out of the test's own refusal so that a craft expected to be refused
--- doesn't read as the test's failure.
function T.craftFrom(self, recipe, from, opts)
    opts = opts or {}
    self.crafts = (self.crafts or 0) + 1
    local label = "craft" .. self.crafts
    local result = { label = label }
    local fromType = type(from) == "table" and from.type or from
    local prefer = { fromType }
    for _, other in ipairs(opts.prefer or {}) do
        table.insert(prefer, other)
    end
    local items, unmatched = T.recipeInputs(recipe, prefer)
    if not T.need(self, #unmatched == 0, "an item for " .. table.concat(unmatched, "; ")) then return result end
    withoutOne(items, fromType)
    if opts.inputs then
        opts.inputs(items)
    end
    if type(from) == "table" then
        table.insert(items, 1, from)
    end
    T.give(self, label, items)
    if opts.setup then
        opts.setup(self)
    end
    local what = "this client's " .. fromType .. " to craft " .. recipe:getName() .. " from"
    if type(from) ~= "table" then
        T.waitForCarried(self, fromType, what)
    end
    T.step(function()
        local item
        if type(from) == "table" then
            item = (self.items[label] or {})[1]
        else
            item = T.carried(fromType)
        end
        if not T.need(self, item, what) then return end
        local id, refusal = item:getID(), self.refusal
        self.refusal = nil
        T.startCraft(self, recipe, item)
        T.step(function() result.refusal, self.refusal = self.refusal, refusal end)
        local types = { fromType }
        for _, other in ipairs(opts.read or {}) do
            table.insert(types, other)
        end
        T.readCarried(self, types, nil, label)
        T.step(function()
            local served = T.findIn(T.carriedItems(self, fromType, label), "id", id)
            result.item = served
            if not served then return end
            T.waitFor(self, function()
                local copy = T.player():getInventory():getItemWithIDRecursiv(id)
                return copy ~= nil and copy:getCondition() == served.condition
                    and copy:getHaveBeenRepaired() == served.repaired and math.abs(copy:getCurrentUsesFloat() - served.uses) < 0.001
            end, "this client's copy of the " .. fromType .. " matching the authority's after " .. recipe:getName())
            T.takeItems(self, { id })
        end)
    end)
    return result
end

--- Expects the craft T.craftFrom's `result` to have started, saying why the game refused if not.
function T.expectCrafted(result, what)
    return T.expect(result.refusal == nil, what .. ": the game refused: " .. tostring(result.refusal))
end

--- Expects the game to have refused the craft T.craftFrom's `result` started from a `fullType` for
--- that item alone: the recipe's OnTest turned it down, for the input line that takes it
--- (T.onTestRefusal). A craft refused for the dark, a skill or another input would otherwise pass
--- for the rule under test.
function T.expectRefusedFor(result, recipe, fullType, what)
    return T.expectEqual(what .. ": why the game refused", result.refusal,
        recipe:getName() .. ": " .. T.onTestRefusal(recipe, fullType))
end

-- `name` without the `recipePrefix` setting, for the rows' messages.
local function shortName(name)
    local prefix = PZHarness.testSettings.recipePrefix or ""
    return name:sub(1, #prefix) == prefix and name:sub(#prefix + 1) or name
end

--- Registers the test `name`, which crafts each row of `rows` in turn (T.craftFrom, after
--- T.readyToCraft) from a new `fullType` at condition `row.before`, repaired `row.repaired` times
--- and charged to `opts.uses` when given. A row is { recipe name, behaviour, before, repaired, and
--- one of: `after` and `repairedAfter`, what the authority's item comes out at; `refused`, the
--- recipe's OnTest turning the item down (T.expectRefusedFor), which leaves it as it was; `used`,
--- the craft using it up }. Messages name a row by its recipe, less the `recipePrefix` setting, and
--- behaviour. `opts.prefer` adds to the inputs preferred, `opts.setup(self)` to every craft's
--- setup, and `opts.validate(row, item, what)` checks more of each item left.
function T.conditionCraftsTest(name, fullType, rows, opts)
    opts = opts or {}
    T.test(name, {
        instant = true,
        run = function(self)
            local names = {}
            for _, row in ipairs(rows) do
                table.insert(names, row[1])
            end
            local recipes = T.readyToCraft(self, names)
            if not recipes then return end
            self.rows = {}
            for i, row in ipairs(rows) do
                self.rows[i] = T.craftFrom(self, recipes[row[1]],
                    { type = fullType, condition = row.before, repaired = row.repaired, uses = opts.uses },
                    { prefer = opts.prefer, setup = opts.setup })
            end
        end,
        validate = function(self)
            for i, row in ipairs(rows) do
                local result, what = self.rows[i], shortName(row[1]) .. ", " .. row[2]
                if row.refused then
                    T.expectRefusedFor(result, getScriptManager():getCraftRecipe(row[1]), fullType, what)
                else
                    T.expectCrafted(result, what)
                end
                local item = result.item
                if row.used then
                    T.expect(item == nil, what .. ": the " .. fullType .. " is still there")
                elseif T.expect(item ~= nil, what .. ": the " .. fullType .. " is gone") then
                    T.expectEqual(what .. ": its condition", item.condition, row.refused and row.before or row.after)
                    T.expectEqual(what .. ": its repairs", item.repaired, row.refused and row.repaired or row.repairedAfter)
                    if opts.validate then
                        opts.validate(row, item, what)
                    end
                end
            end
        end,
    })
end

