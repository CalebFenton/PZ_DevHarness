-- Development only, not published. What the test library's two-sided fixtures do to one side's
-- copy of the game, shared so the client (TestLib.lua) and server (ServerFixtures.lua) make the
-- same change and dev mod server handlers get the lookups too. Each setter returns its undo. The
-- dev mod's test settings live here for the same reason.

PZHarness = PZHarness or {}
local Fixtures = {}
PZHarness.Fixtures = Fixtures

-- What the dev mod passed to PZHarness.registerTests.
PZHarness.testSettings = PZHarness.testSettings or {}

--- Called once by the dev mod, at load, from its shared Lua: a multiplayer server loads no client
--- Lua, and single player reads client and server fixtures alike from this one table, so a hook
--- set here applies whichever side places or removes a fixture. Every setting is optional:
--- - `hour`: the hour every test runs at unless its spec gives one. A test that runs at an hour
---   first waits for the light, which lags the clock.
--- - `perks`: perks restored after every test, however a test changed them.
--- - `sandbox`: the mod's table in SandboxVars, which T.setSandbox tries before the game's options.
--- - `sandboxChanged()`: called on each side after its copy of a sandbox option is set or
---   restored, for state the mod derives from its options.
--- - `setup(self, spec)`: called before every test's spec.run, after its hour and sandbox options;
---   it can push undos with T.defer.
--- - `recipePrefix`: the name prefix of the mod's craftRecipes, for the recipe helpers.
--- - `isFreeSquare(square, indoors)`: where T.squares may put a fixture; by default a walkable
---   square without a vehicle, indoors or outdoors as asked.
--- - `remove(object)`: removes a placed object of the mod the way the mod does, returning true;
---   anything it returns false for goes the vanilla way (Fixtures.removePlaced).
--- - `spawnVehicle(script, square, facing, args)`: makes the vehicles T.placeVehicle asks for, with
---   the test's `opts.args`, returning one, or nil to leave it to addVehicleDebug.
--- - `leakRadius`, `leakLevels`, `leakIgnore`: the runner's leak check (docs/running.md).
--- Hooks that call the dev mod's client or server modules look them up when they run, since those
--- load after shared Lua, and each side loads only its own.
function PZHarness.registerTests(settings)
    PZHarness.testSettings = settings
end

-- The Shoddy Table players build, a crafting surface.
Fixtures.WORK_TABLE_SPRITE = "carpentry_01_60"

--- The table holding sandbox option `key`: SandboxVars[modTable] if it has the option, else
--- SandboxVars if the game has it, else nil; and the option's full name ("Table.Key" or "Key").
function Fixtures.sandboxOptions(modTable, key)
    local mod = modTable and SandboxVars[modTable]
    if mod and mod[key] ~= nil then
        return mod, modTable .. "." .. key
    end
    if SandboxVars[key] ~= nil then
        return SandboxVars, key
    end
end

--- Sets option `key` in `options` and in the game's own copy of option `name` (SandboxOptions),
--- which the game's Java reads instead of SandboxVars (IsoGenerator's GeneratorFuelConsumption,
--- for one), and calls `changed()`, if given, after the change and after the undo.
function Fixtures.setSandbox(options, name, key, value, changed)
    local sandboxOption = getSandboxOptions():getOptionByName(name)
    local option = sandboxOption and sandboxOption:asConfigOption()
    local saved, savedOption = options[key], option and option:getValueAsObject()
    options[key] = value
    if option then option:setValueFromObject(value) end
    if changed then changed() end
    return function()
        options[key] = saved
        if option then option:setValueFromObject(savedOption) end
        if changed then changed() end
    end
end

-- A server computes daylight on its next climate tick but only sends it to clients on periodic
-- ticks (ClimateManager.update), so a clock jump would leave clients in stale light for a while.
-- This makes the next climate tick send it.
local function sendDaylight()
    if isServer() then
        getClimateManager():updateEveryTenMins()
    end
end

function Fixtures.setTime(hour)
    local time = getGameTime()
    local saved = time:getTimeOfDay()
    time:setTimeOfDay(hour)
    sendDaylight()
    return function()
        time:setTimeOfDay(saved)
        sendDaylight()
    end
end

function Fixtures.setMultiplier(multiplier)
    local time = getGameTime()
    local saved = time:getTrueMultiplier()
    time:setMultiplier(multiplier)
    return function() time:setMultiplier(saved) end
end

function Fixtures.setGrid(on)
    local option = getSandboxOptions():getOptionByName("ElecShutModifier")
    local hydro, shut = getWorld():isHydroPowerOn(), option and option:getValue()
    if option then option:setValue(on and 100000 or -1) end
    getWorld():setHydroPowerOn(on)
    return function()
        if option then option:setValue(shut) end
        getWorld():setHydroPowerOn(hydro)
    end
end

function Fixtures.setPerk(player, perk, level)
    local saved = player:getPerkLevel(perk)
    player:setPerkLevelDebug(perk, level)
    return function() player:setPerkLevelDebug(perk, saved) end
end

--- Sets the levels in `levels`, perk ids (perk:getId()) to levels, as they are elsewhere, each with
--- the XP that starts its level. XP left over past the level would level the perk up in a later
--- test, and vanilla's level-up auto-learns recipes (XpUpdate.levelPerk), which the leak check
--- then blames on that test.
function Fixtures.setPerkLevels(player, levels)
    for id, level in pairs(levels) do
        local perk = Perks.FromString(id)
        if perk and perk ~= Perks.MAX then
            player:setPerkLevelDebug(perk, level)
            player:getXp():setXPToLevel(perk, level)
        end
    end
end

--- Timed actions of the character finish in one tick, or take their time. A server makes the
--- actions a client sends it, so it decides their length.
function Fixtures.setInstant(player, on)
    local saved = player:isTimedActionInstantCheat()
    player:setTimedActionInstantCheat(on)
    return function() player:setTimedActionInstantCheat(saved) end
end

--- Vanilla's mechanics cheat on or off: installing and uninstalling a vehicle part then takes one
--- tick and never stops as invalid (ISInstallVehiclePart, ISUninstallVehiclePart). Nothing else
--- of vanilla's but removing a burnt vehicle reads it.
function Fixtures.setMechanicsCheat(player, on)
    local saved = player:isMechanicsCheat()
    player:setMechanicsCheat(on)
    return function() player:setMechanicsCheat(saved) end
end

--- Every perk's level, by perk id, for Fixtures.setPerkLevels.
function Fixtures.perkLevels(player)
    local levels = {}
    for i = 0, PerkFactory.PerkList:size() - 1 do
        local perk = PerkFactory.PerkList:get(i)
        levels[perk:getId()] = player:getPerkLevel(perk)
    end
    return levels
end

function Fixtures.learnRecipes(player, names)
    for _, name in ipairs(names) do
        player:learnRecipe(name)
    end
end

function Fixtures.forgetRecipes(player, names)
    for _, name in ipairs(names) do
        player:getKnownRecipes():remove(name)
    end
end

--- Every recipe the character knows, by name.
function Fixtures.knownRecipes(player)
    local names = {}
    local known = player:getKnownRecipes()
    for i = 0, known:size() - 1 do
        table.insert(names, known:get(i))
    end
    return names
end

--- The first object on `square` drawn as `sprite`, or nil. Takes a nil square.
function Fixtures.objectWithSprite(square, sprite)
    local objects = square and square:getObjects()
    for i = 0, (objects and objects:size() or 0) - 1 do
        if objects:get(i):getTextureName() == sprite then
            return objects:get(i)
        end
    end
    return nil
end

--- How often `fullType` appears in a flat { item, weight, ... } loot list, and its last weight.
function Fixtures.countPairs(items, fullType)
    local count, weight = 0, nil
    for i = 1, #items - 1, 2 do
        if items[i] == fullType then
            count = count + 1
            weight = items[i + 1]
        end
    end
    return count, weight
end

-- How far from `near` vehicleById looks in single player, in squares.
local VEHICLE_SEARCH = 6

--- The vehicle with this id, or nil. A multiplayer server and its clients share vehicle ids
--- (getVehicleById). Single player keeps them elsewhere (VehicleIDMap), so there the vehicle is
--- found over the squares within a few of `near` ({ x, y, z }).
function Fixtures.vehicleById(id, near)
    if id == nil then
        return nil
    end
    local vehicle = getVehicleById(id)
    if vehicle or not near then
        return vehicle
    end
    for dx = -VEHICLE_SEARCH, VEHICLE_SEARCH do
        for dy = -VEHICLE_SEARCH, VEHICLE_SEARCH do
            local square = getSquare(near.x + dx, near.y + dy, near.z)
            local found = square and square:getVehicleContainer()
            if found and found:getId() == id then
                return found
            end
        end
    end
    return nil
end

--- Iterates over every square at Chebyshev distance exactly `r` from (x, y), each once, as
--- `for sx, sy in Fixtures.ring(x, y, r) do`; (x, y) itself when `r` is 0. Rings of growing `r`
--- make a nearest-first search that skips the squares smaller rings already tried.
function Fixtures.ring(x, y, r)
    -- Column by column from the west, each north to south: the edge columns whole, the ones
    -- between only their two ends.
    local dx, dy = -r, -r - 1
    return function()
        if math.abs(dx) == r and dy < r then
            dy = dy + 1
        elseif dy < r then
            dy = r
        else
            dx = dx + 1
            if dx > r then
                return nil
            end
            dy = -r
        end
        return x + dx, y + dy
    end
end

--- Turns `car` and `trailer` square to `facing` ("N", "E", "S" or "W") and moves the trailer so its
--- coupler sits on the car's tow bar: vanilla hitches only with the two points within a square and
--- the vehicles near parallel (BaseVehicle.canAttachTrailer), and addVehicleDebug skews headings at
--- random, so an unaligned hitch can fail or jackknife.
function Fixtures.lineUpTrailer(car, trailer, facing)
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

-- The squares next to a fixture's anchor, in the order every search tries them.
local ADJACENT = { IsoDirections.N, IsoDirections.W, IsoDirections.S, IsoDirections.E }

--- A free square next to `here`, with no wall in between, that isn't a key of `used` (if given),
--- or nil.
function Fixtures.freeAdjacentSquare(here, used)
    for _, direction in ipairs(ADJACENT) do
        local square = here and here:getAdjacentSquare(direction)
        if square and not (used and used[square]) and square:isFree(false) and not here:isBlockedTo(square) then
            return square
        end
    end
    return nil
end

-- Adds `object` to its square and sends it to the clients when this is a server.
local function addToSquare(square, object)
    square:AddTileObject(object)
    if isServer() then
        object:transmitCompleteItemToClients()
    end
end

--- A new tile object of `sprite` on `square`, with `modData`, sent to the clients when this is a
--- server. Returns it.
function Fixtures.newTile(square, sprite, modData)
    local object = IsoObject.new(square, sprite, "PZHarness")
    for key, value in pairs(modData or {}) do
        object:getModData()[key] = value
    end
    addToSquare(square, object)
    return object
end

--- A new workstation of the entity script `entity` (such as "Base.Kiln_Small"), drawn as
--- `sprite`, on `square`, sent to the clients when this is a server, which `player` is using as
--- its crafting window makes them. Returns it, or nil without the script; and what is missing when
--- the script makes no craft bench, the bench then placed all the same so the caller removes it.
function Fixtures.newBench(square, entity, sprite, player)
    local script = getScriptManager():getGameEntityScript(entity)
    if not script then
        return nil, "the entity script " .. entity
    end
    local bench = IsoObject.new(square, sprite, entity)
    GameEntityFactory.CreateIsoObjectEntity(bench, script, true)
    addToSquare(square, bench)
    if not bench:getComponent(ComponentType.CraftBench) then
        return bench, "a craft bench in " .. entity
    end
    bench:setUsingPlayer(player)
    return bench
end

--- Removes what a test placed (an IsoObject or a vehicle) the way the game does, so the mods'
--- removal handlers run, and a server sends the removal to its clients: the dev mod's `remove`
--- setting first, then vanilla's. Does nothing to an object already gone from its square.
function Fixtures.removePlaced(thing)
    if instanceof(thing, "BaseVehicle") then
        thing:permanentlyRemove()
        return
    end
    if thing:getObjectIndex() == -1 then
        return
    end
    local remove = PZHarness.testSettings.remove
    if remove and remove(thing) then
        return
    end
    -- Squares stay powered by a running generator that leaves them.
    if instanceof(thing, "IsoGenerator") and thing:isActivated() then
        thing:setActivated(false)
    end
    thing:getSquare():transmitRemoveItemFromSquare(thing)
end

local function isWorkTable(object)
    local sprite = object:getSprite()
    return sprite ~= nil and sprite:getName() == Fixtures.WORK_TABLE_SPRITE
end

--- The work table next to the character, or nil.
function Fixtures.workTableNear(player)
    local here = player:getSquare()
    for _, direction in ipairs(ADJACENT) do
        local square = here and here:getAdjacentSquare(direction)
        local objects = square and square:getObjects()
        for i = 0, (objects and objects:size() or 0) - 1 do
            if isWorkTable(objects:get(i)) then
                return objects:get(i)
            end
        end
    end
    return nil
end

--- Puts a work table on a free square next to the character, with no wall in between, unless one
--- is there already, and sends it to the clients when this is a server. IsoObject.new with a name
--- gives the object the sprite's properties, Surface included. Returns the table, or nil without
--- a free square.
function Fixtures.placeWorkTable(player)
    local existing = Fixtures.workTableNear(player)
    if existing then
        return existing
    end
    local square = Fixtures.freeAdjacentSquare(player:getSquare())
    if not square then
        return nil
    end
    local object = IsoObject.new(square, Fixtures.WORK_TABLE_SPRITE, "Table")
    addToSquare(square, object)
    return object
end

--- The runner's reset before every test: full health, an empty inventory, nothing worn or held.
--- A server also tells the clients what was worn and held.
function Fixtures.resetCharacter(player)
    player:getBodyDamage():RestoreToFullHealth()
    player:getInventory():removeAllItems()
    player:clearWornItems()
    player:setPrimaryHandItem(nil)
    player:setSecondaryHandItem(nil)
    if isServer() then
        syncVisuals(player)
        sendEquip(player)
    end
end

--- Puts the character in the middle of the square at x, y, z. teleportTo alone leaves it on the
--- square's north-west corner (IsoGameCharacter.teleportTo floors), from where vanilla's walkAdj
--- counts a square two to the north or west as within reach (1.6 tiles of its middle) and walks
--- nowhere, while actions that need the square adjacent, such as ISMoveablesAction, then stop and
--- empty the queue.
function Fixtures.teleportToMiddle(player, x, y, z)
    player:teleportTo(x, y, z)
    player:setX(x + 0.5)
    player:setY(y + 0.5)
    player:setLastX(x + 0.5)
    player:setLastY(y + 0.5)
end

--- Changes `item` as `changes` says: `condition`, `uses` (the fraction of a full drainable item,
--- setCurrentUsesFloat), `modData` (keys to set). Returns the item.
function Fixtures.changeItem(item, changes)
    if changes.condition then
        item:setCondition(changes.condition)
    end
    if changes.uses then
        item:setCurrentUsesFloat(changes.uses)
    end
    for key, value in pairs(changes.modData or {}) do
        item:getModData()[key] = value
    end
    return item
end

return Fixtures
