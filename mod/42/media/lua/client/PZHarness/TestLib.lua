require "Tests/TimedActionsTests"
require "Moveables/ISMoveableSpriteProps"
require "PZHarness/Runner"

-- The generic half of a mod's test library. A mod's own library inherits from it
-- (setmetatable(ModTest, { __index = PZHarness.Test })) and adds the fixtures that know the mod's
-- objects; its test files register tests with the vanilla timed action test runner through
-- T.test. The runner (the debug menu's Dev > Unit Tests > Timed Actions, or PZHarness/Runner.lua)
-- calls run(), waits until the character's action queue is empty, then calls validate(). Before
-- each test it empties the inventory and the hands, clears worn items and teleports the character
-- back; perks, known recipes, modData, world objects, sandbox options and the clock carry over.
-- Each result goes to console.txt as "<tag> PASS <name>" or "<tag> FAIL <name>: <reasons>".
--
-- Settings, from the `tests` table the dev mod passes to PZHarness.register, all optional:
-- - `hour`: the hour every test runs at unless its spec gives one. A test that runs at an hour
--   first waits for the light, which lags the clock.
-- - `perks`: perks restored after every test, however a test changed them.
-- - `sandbox`: the mod's table in SandboxVars, which T.setSandbox tries before the game's options.
-- - `sandboxChanged()`: called after T.setSandbox sets or restores an option, for state the mod
--   derives from its options.
-- - `setup(self, spec)`: called before every test's spec.run, after its hour and sandbox options;
--   it can push undos with T.defer.
-- - `recipePrefix`: the name prefix of the mod's craftRecipes, for the recipe helpers.
-- - `isFreeSquare(square, indoors)`: where T.squares may put a fixture; by default a walkable
--   square without a vehicle, indoors or outdoors as asked.
-- - `remove(object)`: removes a placed object of the mod the way the mod does, returning true;
--   anything it returns false for T.track removes the vanilla way.
--
-- Rules of the API, so that no test depends on what an earlier one left:
-- - T.test gives every run a fresh `self`, sets the clock to the hour, runs timed actions
--   instantly when `spec.instant` (otherwise at their real duration), and applies `spec.sandbox`.
-- - Each T.set* call, T.defer, T.onTick and every fixture (T.tile, T.bench, T.placeMoveable,
--   T.vehicle, T.track and the mod's) pushes its undo onto the test's restore stack. After
--   validate and `spec.cleanup`, the wrapper unwinds it newest first: it removes what the test
--   placed (running generators switched off first, vehicles permanently) and restores the clock,
--   perks, grid, sandbox options, game speed and the instant cheat.
-- - A fixture that can't be built records what is missing (T.need); the wrapper then fails the
--   test with it and skips spec.validate, so validate never indexes a missing fixture.
-- - A Lua error stops the game in the debug-mode error handler, pcall or not, and the runner never
--   finishes, so tests never throw.
PZHarness.Test = {}
local T = PZHarness.Test

-- The longest a test waits for the light to follow the clock or the grid. The lighting catches up
-- at its own pace in real time, so at a high frame rate it takes more ticks.
local LIGHT_FRAMES = 600
-- Squares searched around a fixture's centre, in tiles.
local SEARCH_RADIUS = 30
-- Squares a vehicle is tried on before a test gives up on it.
local VEHICLE_TRIES = 8

local function settings()
    return PZHarness.config.tests
end

function T.player()
    return getSpecificPlayer(0)
end

-- Expectations ---------------------------------------------------------------------------------

-- Unmet expectations of the test being validated.
local failures = {}

function T.expect(condition, message)
    if not condition then
        table.insert(failures, message)
    end
    return condition
end

function T.expectNear(label, actual, expected, tolerance)
    return T.expect(type(actual) == "number" and math.abs(actual - expected) <= (tolerance or 0.0001),
        label .. " is " .. tostring(actual) .. ", expected " .. expected)
end

--- Returns `value`; when it is nil or false, records `what` (a noun phrase: "a free indoor square
--- for a table") as missing, which fails the test without running spec.validate.
function T.need(self, value, what)
    if not value then
        table.insert(self.missing, what)
    end
    return value
end

-- Restore stack --------------------------------------------------------------------------------

--- Runs `undo` when the test ends, before the undos pushed earlier.
function T.defer(self, undo)
    table.insert(self.undo, undo)
end

--- Calls `fn` every tick until the test ends.
function T.onTick(self, fn)
    Events.OnTick.Add(fn)
    T.defer(self, function() Events.OnTick.Remove(fn) end)
end

function T.setTime(self, hour)
    local time = getGameTime()
    local saved = time:getTimeOfDay()
    T.defer(self, function() time:setTimeOfDay(saved) end)
    time:setTimeOfDay(hour)
end

function T.setPerk(self, perk, level)
    local p = T.player()
    local saved = p:getPerkLevel(perk)
    T.defer(self, function() p:setPerkLevelDebug(perk, saved) end)
    p:setPerkLevelDebug(perk, level)
end

local function sandboxChanged()
    if settings().sandboxChanged then
        settings().sandboxChanged()
    end
end

--- Sets a sandbox option of the mod (SandboxVars[settings.sandbox]) or, failing that, of the
--- game. An option in neither is recorded as missing rather than created.
function T.setSandbox(self, key, value)
    local mod = settings().sandbox and SandboxVars[settings().sandbox]
    local options = mod and mod[key] ~= nil and mod or SandboxVars[key] ~= nil and SandboxVars
    if not T.need(self, options, "the sandbox option " .. key) then return end
    local saved = options[key]
    T.defer(self, function()
        options[key] = saved
        sandboxChanged()
    end)
    options[key] = value
    sandboxChanged()
end

--- The game runs `multiplier` times as fast: the clock and every timed action alike. The game drops
--- back to 1 when the character moves without a path or a zombie comes close.
function T.setMultiplier(self, multiplier)
    local time = getGameTime()
    local saved = time:getTrueMultiplier()
    T.defer(self, function() time:setMultiplier(saved) end)
    time:setMultiplier(multiplier)
end

--- The power grid on or off.
function T.setGrid(self, on)
    local option = getSandboxOptions():getOptionByName("ElecShutModifier")
    local hydro, shut = getWorld():isHydroPowerOn(), option and option:getValue()
    T.defer(self, function()
        if option then option:setValue(shut) end
        getWorld():setHydroPowerOn(hydro)
    end)
    if option then option:setValue(on and 100000 or -1) end
    getWorld():setHydroPowerOn(on)
end

-- Queue ----------------------------------------------------------------------------------------

-- Holds the action queue, so the runner validates only once the world has caught up: until
-- `done()` holds or `total` ticks pass, calling `onTick(n)` every tick.
local Wait = ISBaseTimedAction:derive("PZHarnessWait")

function Wait:isValid()
    return true
end

function Wait:update()
    self.ticks = self.ticks + 1
    if self.onTick then
        self.onTick(self.ticks)
    end
    if self.ticks >= self.total or (self.done and self.done()) then
        self:forceComplete()
    end
end

function Wait:new(character, total, onTick, done)
    local o = ISBaseTimedAction.new(self, character)
    o.total, o.onTick, o.done, o.ticks = total, onTick, done, 0
    o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
    o.maxTime = -1
    return o
end

--- Queues `ticks` ticks of waiting, calling `onTick(n)` every tick.
function T.wait(ticks, onTick)
    ISTimedActionQueue.add(Wait:new(T.player(), ticks, onTick))
end

--- Queues a wait that ends as soon as `condition()` holds, or after `maxFrames` ticks; the
--- following validate checks what it waited for.
function T.waitUntil(condition, maxFrames)
    ISTimedActionQueue.add(Wait:new(T.player(), maxFrames, nil, condition))
end

--- Runs `fn` once the actions queued before it are done.
function T.step(fn)
    ISTimedActionQueue.add(Wait:new(T.player(), 1, function() fn() end))
end

local function lit()
    return not T.player():tooDarkToRead()
end

--- Midnight with the grid off, dark where the character stands; queues a wait for the light to
--- follow the clock.
function T.makeDark(self)
    T.setGrid(self, false)
    T.setTime(self, 0)
    T.waitUntil(function() return not lit() end, LIGHT_FRAMES)
end

-- Registering tests ----------------------------------------------------------------------------

--- Registers test `name`. `spec`: run(self), validate(self), cleanup(self), all optional; `hour`;
--- `instant`; `sandbox` (option = value, see T.setSandbox); anything else the mod's setup reads.
function T.test(name, spec)
    local function start(self, hour)
        local p = T.player()
        local cheat = p:isTimedActionInstantCheat()
        T.defer(self, function() p:setTimedActionInstantCheat(cheat) end)
        p:setTimedActionInstantCheat(spec.instant == true)
        if hour then
            T.setTime(self, hour)
        end
        for key, value in pairs(spec.sandbox or {}) do
            T.setSandbox(self, key, value)
        end
        if settings().setup then
            settings().setup(self, spec)
        end
        if spec.run and #self.missing == 0 then
            spec.run(self)
        end
    end
    TimedActionTests.getTests()[name] = {
        run = function(entry)
            local self = { undo = {}, missing = {}, used = {} }
            entry.state = self
            local p = T.player()
            for _, perk in pairs(settings().perks or {}) do
                local level = p:getPerkLevel(perk)
                T.defer(self, function() p:setPerkLevelDebug(perk, level) end)
            end
            -- Read now, not when the test registers: the dev mod may register its settings after
            -- its test files have loaded.
            local hour = spec.hour or settings().hour
            -- The light lags a clock or grid change by some frames, and the previous test may
            -- have ended in the dark.
            if not hour or lit() then
                start(self, hour)
            else
                T.waitUntil(lit, LIGHT_FRAMES)
                T.step(function() start(self, hour) end)
            end
        end,
        validate = function(entry)
            local self = entry.state or { undo = {}, missing = { "a run before validate" } }
            entry.state = nil
            failures = {}
            if #self.missing > 0 then
                table.insert(failures, "missing " .. table.concat(self.missing, "; "))
            elseif spec.validate then
                spec.validate(self)
            end
            if spec.cleanup then
                spec.cleanup(self)
            end
            for i = #self.undo, 1, -1 do
                self.undo[i]()
            end
            if #failures > 0 then
                print(PZHarness.run.tag .. " FAIL " .. name .. ": " .. table.concat(failures, "; "))
                return false
            end
            print(PZHarness.run.tag .. " PASS " .. name)
            return true
        end,
    }
end

-- Squares --------------------------------------------------------------------------------------

local function squareOf(near)
    if not near then
        return T.player():getCurrentSquare()
    end
    return instanceof(near, "IsoGridSquare") and near or near:getSquare()
end

local function isFreeSquare(square, indoors)
    if settings().isFreeSquare then
        return settings().isFreeSquare(square, indoors)
    end
    return square:isFree(false) and square:getVehicleContainer() == nil and square:isOutside() ~= indoors
end

-- Up to `count` free squares; see T.squares.
local function freeSquares(self, count, opts)
    local center = squareOf(opts.near)
    local found = {}
    if not center then return found end
    for radius = opts.minDistance or 1, SEARCH_RADIUS do
        for dx = -radius, radius do
            for dy = -radius, radius do
                local square = math.max(math.abs(dx), math.abs(dy)) == radius
                    and getSquare(center:getX() + dx, center:getY() + dy, center:getZ())
                if #found < count and square and not self.used[square]
                    and isFreeSquare(square, opts.indoors == true)
                    and (not opts.bare or square:getObjects():size() == 1) then
                    self.used[square] = true
                    table.insert(found, square)
                end
            end
        end
    end
    return found
end

--- `count` free squares (the `isFreeSquare` setting) around `opts.near` (a square or object; the
--- character's square by default), nearest first and at least `opts.minDistance` tiles away:
--- indoors when `opts.indoors`, else outdoors; holding only their floor when `opts.bare`. Each
--- square goes to one fixture per test. Nil unless all are found.
function T.squares(self, count, opts)
    local found = freeSquares(self, count, opts or {})
    return #found == count and found or nil
end

-- Fixtures -------------------------------------------------------------------------------------

--- Removes `thing` (an IsoObject or a vehicle) when the test ends, the way the game does, so the
--- mods' removal handlers run. Returns `thing`.
function T.track(self, thing)
    T.defer(self, function()
        if instanceof(thing, "BaseVehicle") then
            thing:permanentlyRemove()
        elseif thing:getObjectIndex() ~= -1 then
            if settings().remove and settings().remove(thing) then
                return
            end
            -- Squares stay powered by a running generator that leaves them.
            if instanceof(thing, "IsoGenerator") and thing:isActivated() then
                thing:setActivated(false)
            end
            thing:getSquare():transmitRemoveItemFromSquare(thing)
        end
    end)
    return thing
end

--- A tile object of `sprite` on `square`, with `modData`.
function T.tile(self, square, sprite, modData)
    local object = IsoObject.new(square, sprite, "PZHarness")
    for key, value in pairs(modData or {}) do
        object:getModData()[key] = value
    end
    square:AddTileObject(object)
    return T.track(self, object)
end

--- Places a new `itemType` on `square` the way the moveables cursor does, with `modData` on the
--- item first. Returns the placed object.
function T.placeMoveable(self, square, itemType, sprite, modData)
    local item = instanceItem(itemType)
    for key, value in pairs(modData or {}) do
        item:getModData()[key] = value
    end
    T.player():getInventory():AddItem(item)
    ISMoveableSpriteProps.new(sprite):placeMoveable(T.player(), square, item:getWorldSprite(), true)
    local object = T.objectWithSprite(square, sprite)
    return T.need(self, object and T.track(self, object), "a placed " .. itemType)
end

--- A workstation of the entity script `entity` (such as "Base.Kiln_Small"), drawn as `sprite`,
--- on a free square next to the character, who is using it as its crafting window makes them.
--- Returns the object.
function T.bench(self, entity, sprite)
    local script = T.need(self, getScriptManager():getGameEntityScript(entity), "the entity script " .. entity)
    local here = T.player():getSquare()
    local square
    for _, direction in ipairs({ IsoDirections.S, IsoDirections.E, IsoDirections.N, IsoDirections.W }) do
        local next = here:getAdjacentSquare(direction)
        if not square and next and not self.used[next] and next:isFree(false) and not here:isBlockedTo(next) then
            square = next
        end
    end
    if not (script and T.need(self, square, "a free square next to the character for a " .. entity)) then
        return nil
    end
    self.used[square] = true
    local bench = IsoObject.new(square, sprite, entity)
    GameEntityFactory.CreateIsoObjectEntity(bench, script, true)
    square:AddTileObject(bench)
    T.track(self, bench)
    bench:setUsingPlayer(T.player())
    return T.need(self, bench:getComponent(ComponentType.CraftBench) and bench, "a craft bench in " .. entity)
end

--- A vehicle of `script` facing north on `opts.square`, else on open ground near `opts.near`
--- (the character by default). Returns the vehicle.
function T.vehicle(self, script, opts)
    opts = opts or {}
    -- Far enough that the vehicle doesn't land on the character.
    local squares = opts.square and { opts.square }
        or freeSquares(self, VEHICLE_TRIES, { near = opts.near, minDistance = 4, bare = true })
    for _, square in ipairs(squares) do
        -- addVehicleDebug returns a vehicle even where it leaves it out of the world, as it does
        -- where it would hit another vehicle; only a vehicle in the world gets an id
        -- (BaseVehicle.createPhysics).
        local vehicle = addVehicleDebug(script, IsoDirections.N, nil, square)
        if vehicle and vehicle:getId() ~= -1 then
            return T.track(self, vehicle)
        end
    end
    T.need(self, nil, "open ground for a " .. script)
    return nil
end

--- Turns `car` and `trailer` square to `facing` ("N", "E", "S" or "W") and moves the trailer so its
--- coupler sits on the car's tow bar, as a player lines them up to hitch: vanilla hitches a trailer
--- only with the two points within a square and the vehicles near parallel
--- (BaseVehicle.canAttachTrailer). addVehicleDebug skews each heading by up to about 11 degrees at
--- random, and a hitch left to pull a trailer in from farther off can fail to or jackknife it.
function T.lineUpTrailer(car, trailer, facing)
    -- The rotation addVehicleDebug gives a heading, before its random skew.
    local yaw = ((IsoDirections[facing]:toAngle() + math.pi) * 180 / math.pi) % 360
    car:setAngles(0, yaw, 0)
    trailer:setAngles(0, yaw, 0)
    local towing = car:getTowingWorldPos("trailer", Vector3f.new())
    local towed = trailer:getTowedByWorldPos("trailer", Vector3f.new())
    local transform = trailer:getWorldTransform(Transform.new())
    local origin = transform:getOrigin()
    -- The transform's x and z are the world's x and y.
    origin:set(origin:x() + towing:x() - towed:x(), origin:y(), origin:z() + towing:y() - towed:y())
    trailer:setWorldTransform(transform)
end

-- Lookups and data -----------------------------------------------------------------------------

--- The first object on `square` drawn as `sprite`, or nil. Takes a nil square.
function T.objectWithSprite(square, sprite)
    local objects = square and square:getObjects()
    for i = 0, (objects and objects:size() or 0) - 1 do
        if objects:get(i):getTextureName() == sprite then
            return objects:get(i)
        end
    end
    return nil
end

--- How often `fullType` appears in a flat { item, weight, ... } loot list, and its last weight.
function T.countPairs(items, fullType)
    local count, weight = 0, nil
    for i = 1, #items - 1, 2 do
        if items[i] == fullType then
            count = count + 1
            weight = items[i + 1]
        end
    end
    return count, weight
end

-- Recipes --------------------------------------------------------------------------------------

--- Every craftRecipe whose name starts with `prefix` (the `recipePrefix` setting by default).
function T.recipeNames(prefix)
    prefix = prefix or settings().recipePrefix or ""
    local names = {}
    local recipes = getScriptManager():getAllCraftRecipes()
    for i = 0, recipes:size() - 1 do
        local name = recipes:get(i):getName()
        if PZHarness.startsWith(name, prefix) then
            table.insert(names, name)
        end
    end
    return names
end

function T.learnRecipes(player, prefix)
    for _, name in ipairs(T.recipeNames(prefix)) do
        player:learnRecipe(name)
    end
end

function T.forgetRecipes(player, prefix)
    for _, name in ipairs(T.recipeNames(prefix)) do
        player:getKnownRecipes():remove(name)
    end
end

local function pickInputItem(possible, prefer)
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

--- Adds what one craft of `recipe` takes, tools included. Each input gets the first of its
--- possible items listed in `prefer`, else its first possible item other than a generic
--- Base.Moveable. A drainable input that counts uses gets one full item. Returns the inputs that
--- had no possible item at all.
function T.addRecipeInputs(player, recipe, prefer)
    local inventory = player:getInventory()
    local unmatched = {}
    local inputs = recipe:getInputs()
    for i = 0, inputs:size() - 1 do
        local input = inputs:get(i)
        local item = pickInputItem(input:getPossibleInputItems(), prefer)
        if item then
            local count = input:getIntAmount()
            if item:isItemType(ItemType.DRAINABLE) and not input:isItemCount() then
                count = 1
            end
            inventory:AddItems(item:getFullName(), count)
        else
            table.insert(unmatched, input:getOriginalLine())
        end
    end
    return unmatched
end

local WORK_TABLE_SPRITE = "carpentry_01_60" -- the Shoddy Table players build, a crafting surface

local function isWorkTable(object)
    local sprite = object:getSprite()
    return sprite ~= nil and sprite:getName() == WORK_TABLE_SPRITE
end

--- AnySurfaceCraft recipes need a table the character can walk to. Puts one on a free square next
--- to the character, with no wall in between, unless one is there already. IsoObject.new with a
--- name gives the object the sprite's properties, Surface included. Not undone: scenarios call it
--- too, and a table left standing harms no later test.
function T.placeWorkTable(player)
    local here = player:getSquare()
    local free
    for _, direction in ipairs({ IsoDirections.N, IsoDirections.W, IsoDirections.S, IsoDirections.E }) do
        local square = here:getAdjacentSquare(direction)
        local objects = square and square:getObjects()
        for i = 0, (objects and objects:size() or 0) - 1 do
            if isWorkTable(objects:get(i)) then
                return
            end
        end
        if not free and square and square:isFree(false) and not here:isBlockedTo(square) then
            free = square
        end
    end
    assert(free, "PZHarness: no free square next to the character for a table")
    free:AddTileObject(IsoObject.new(free, WORK_TABLE_SPRITE, "Table"))
end

-- Crafting -------------------------------------------------------------------------------------

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

--- Starts crafting `recipe` from the item `from` the way the right-click menu does or, with
--- `bench` (from T.bench), the way the bench's crafting window does. Adds why the game refused
--- to `self.refusal`.
function T.startCraft(self, recipe, from, bench)
    local refusal = T.craftRefusal(recipe, from, bench)
    if refusal then
        self.refusal = (self.refusal and self.refusal .. "; " or "") .. recipe:getName() .. ": " .. refusal
    end
    if bench then
        ISEntityUI.HandcraftStart(T.player(), craftLogic(recipe, from, bench), false, true)
    else
        ISInventoryPaneContextMenu.OnNewCraft(from, recipe, T.player():getPlayerNum(), false)
    end
end

-- How many `fullType` lie on the floor around the character, removing them. A craft whose output
-- doesn't fit drops it at the character's feet (Actions.addOrDropItem).
local function takeDropped(fullType)
    local here, count = T.player():getCurrentSquare(), 0
    for dx = -1, 1 do
        for dy = -1, 1 do
            local square = here and getSquare(here:getX() + dx, here:getY() + dy, here:getZ())
            local objects = square and square:getWorldObjects()
            for i = (objects and objects:size() or 0) - 1, 0, -1 do
                if objects:get(i):getItem():getFullType() == fullType then
                    count = count + 1
                    square:removeWorldObject(objects:get(i))
                end
            end
        end
    end
    return count
end

--- Registers a test that crafts `spec.recipe` from the first `spec.from` item the way the
--- right-click menu does or, with `spec.bench` ({ entity script, sprite }, see T.bench), at that
--- workstation the way its crafting window does; instantly unless `spec.instant` is false. The
--- character knows every recipe of the mod, has at least the levels the recipe requires, stands
--- by a table, and carries exactly the inputs of one craft (T.addRecipeInputs with `spec.prefer`)
--- and whatever `spec.setup(self)` adds. validate() expects the counts in `spec.counts`, in the
--- inventory or dropped at the character's feet, then runs `spec.validate(self)`. A failing test
--- also reports why the game refused the craft.
function T.craftTest(name, spec)
    T.test(name, {
        sandbox = spec.sandbox,
        hour = spec.hour,
        instant = spec.instant ~= false,
        run = function(self)
            local p = T.player()
            local recipe = T.need(self, getScriptManager():getCraftRecipe(spec.recipe), "the recipe " .. spec.recipe)
            if not recipe then return end
            T.learnRecipes(p)
            T.placeWorkTable(p)
            local bench = spec.bench and T.bench(self, spec.bench[1], spec.bench[2])
            if spec.bench and not bench then return end
            for i = 0, recipe:getRequiredSkillCount() - 1 do
                local skill = recipe:getRequiredSkill(i)
                if p:getPerkLevel(skill:getPerk()) < skill:getLevel() then
                    T.setPerk(self, skill:getPerk(), skill:getLevel())
                end
            end
            local unmatched = T.addRecipeInputs(p, recipe, spec.prefer)
            if not T.need(self, #unmatched == 0, "an item for " .. table.concat(unmatched, "; ")) then return end
            if spec.setup then
                spec.setup(self)
            end
            local from = T.need(self, p:getInventory():getFirstTypeRecurse(spec.from), "a " .. spec.from .. " to craft from")
            if not from then return end
            T.startCraft(self, recipe, from, bench)
        end,
        validate = function(self)
            local before = #failures
            for fullType, count in pairs(spec.counts or {}) do
                local actual = T.player():getInventory():getCountTypeRecurse(fullType) + takeDropped(fullType)
                T.expect(actual == count, actual .. " " .. fullType .. ", expected " .. count)
            end
            if spec.validate then
                spec.validate(self)
            end
            if #failures > before and self.refusal then
                table.insert(failures, "the game refused the craft: " .. self.refusal)
            end
        end,
    })
end

return T
