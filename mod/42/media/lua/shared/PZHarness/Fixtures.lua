-- Development only, not published. What the test library's two-sided fixtures do to one side's
-- copy of the game, shared so the client (TestLib.lua) and server (ServerFixtures.lua) make the
-- same change and dev mod server handlers get the lookups too. Each setter returns its undo. The
-- dev mod's test settings and the two-sided fixtures (Fixtures.TWO_SIDED) live here for the same
-- reason.

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
--- - `sandbox`: the mod's table in SandboxVars, which T.setSandbox tries before the game's options
---   and Fixtures.saveOptions saves from.
--- - `sandboxChanged()`: called on each side after its copy of a sandbox option is set or
---   restored, for state the mod derives from its options.
--- - `setup(self, spec)`: called before every test's spec.run, after its hour and sandbox options;
---   it can push undos with T.defer.
--- - `recipePrefix`: the name prefix of the mod's craftRecipes, for the recipe helpers.
--- - `isFreeSquare(square, indoors)`: where T.squares may put a fixture; by default a walkable
---   square without a vehicle, indoors or outdoors as asked.
--- - `remove(object, player)`: removes a placed object of the mod the way the mod does, returning
---   true; anything it returns false for goes the vanilla way (Fixtures.removePlaced). `player` is
---   the character whose test placed it, when the remover knows it.
--- - `spawnVehicle(script, square, facing, args, defer)`: makes the vehicles T.placeVehicle asks
---   for, with the test's `opts.args`, returning one, or nil to leave it to addVehicleDebug;
---   `defer` takes undos, as a handler's does.
--- - `chance()`: the mod's roll module, whose `roll()` every chance of the mod draws through
---   (PZHarness.Rolls).
--- - `records`: the kinds of Global Object System record the record kit drives
---   (server/PZHarness/ServerRecords.lua), by kind name.
--- - `jobAction()`: the mod's job action class, for the job kit (server/PZHarness/ServerJobs.lua).
--- - `leakRadius`, `leakLevels`, `leakIgnore`: the runner's leak check (docs/running.md).
--- Hooks that call the dev mod's client or server modules look them up when they run, since those
--- load after shared Lua, and each side loads only its own.
function PZHarness.registerTests(settings)
    PZHarness.testSettings = settings
end

-- The Shoddy Table players build, a crafting surface.
Fixtures.WORK_TABLE_SPRITE = "carpentry_01_60"

-- The table holding sandbox option `key`: SandboxVars[modTable] if it has the option, else
-- SandboxVars if the game has it, else nil; and the option's full name ("Table.Key" or "Key").
local function sandboxOptions(modTable, key)
    local mod = modTable and SandboxVars[modTable]
    if mod and mod[key] ~= nil then
        return mod, modTable .. "." .. key
    end
    if SandboxVars[key] ~= nil then
        return SandboxVars, key
    end
end

-- Calls the dev mod's `sandboxChanged` setting, if any, after a sandbox option changed.
local function sandboxChanged()
    if PZHarness.testSettings.sandboxChanged then
        PZHarness.testSettings.sandboxChanged()
    end
end

-- Sets option `key` in `options` and in the game's own copy of option `name` (SandboxOptions),
-- which the game's Java reads instead of SandboxVars (IsoGenerator's GeneratorFuelConsumption,
-- for one), and calls sandboxChanged after the change and after the undo.
local function setSandbox(options, name, key, value)
    local sandboxOption = getSandboxOptions():getOptionByName(name)
    local option = sandboxOption and sandboxOption:asConfigOption()
    local saved, savedOption = options[key], option and option:getValueAsObject()
    options[key] = value
    if option then option:setValueFromObject(value) end
    sandboxChanged()
    return function()
        options[key] = saved
        if option then option:setValueFromObject(savedOption) end
        sandboxChanged()
    end
end

--- Defers `undo` for a server handler that changes shared state, and returns the function that
--- runs it now, which the handler calls when done. Being deferred too, it still runs when the
--- handler throws first (the harness unwinds a failed call at once). It runs once either way.
function Fixtures.deferOnce(defer, undo)
    local done = false
    local function once()
        if done then
            return
        end
        done = true
        undo()
    end
    defer(once)
    return once
end

--- Sets `target[key]` to `value`, a production function or field a test stands in for, and returns
--- the function that puts back what stood there before; Fixtures.deferOnce says when it runs.
function Fixtures.replace(defer, target, key, value)
    local before = target[key]
    target[key] = value
    return Fixtures.deferOnce(defer, function() target[key] = before end)
end

--- Saves the options `names` of the mod's table in SandboxVars (the `sandbox` test setting) for a
--- server handler that changes them, and returns the function that puts them back and then calls
--- `reapply`, if given, to rebuild what the mod made from them; Fixtures.deferOnce says when it
--- runs. Unlike setSandbox it leaves the game's SandboxOptions alone, for a handler that changes
--- the options many times and reapplies them itself.
function Fixtures.saveOptions(defer, names, reapply)
    local options, saved = SandboxVars[PZHarness.testSettings.sandbox], {}
    for _, name in ipairs(names) do
        saved[name] = options[name]
    end
    return Fixtures.deferOnce(defer, function()
        for _, name in ipairs(names) do
            options[name] = saved[name]
        end
        if reapply then
            reapply()
        end
    end)
end

-- A server computes daylight on its next climate tick but only sends it to clients on periodic
-- ticks (ClimateManager.update), so a clock jump would leave clients in stale light for a while.
-- This makes the next climate tick send it.
local function sendDaylight()
    if isServer() then
        getClimateManager():updateEveryTenMins()
    end
end

--- Sets the clock to `hour` and returns the undo, which puts back the date too: a test that runs
--- the clock past midnight moves the world to the next day (GameTime.advanceOneDay), and the world's
--- age counts the nights survived.
function Fixtures.setTime(hour)
    local time = getGameTime()
    local timeOfDay, day, month, year, nights = time:getTimeOfDay(), time:getDay(), time:getMonth(),
        time:getYear(), time:getNightsSurvived()
    time:setTimeOfDay(hour)
    sendDaylight()
    return function()
        time:setTimeOfDay(timeOfDay)
        time:setDay(day)
        time:setMonth(month)
        time:setYear(year)
        time:setNightsSurvived(nights)
        time:updateCalendar(year, month, day, math.floor(timeOfDay), time:getMinutes())
        sendDaylight()
    end
end

--- A clear, still day at once: no cloud, fog or rain however the weather turns from then on. The
--- admin values hold until switched off; stopping the weather alone leaves its fog to fade out over
--- seconds. A server sends the sky to its clients (ClimateManager.transmitServerStopWeather).
function Fixtures.clearWeather()
    local climate = getClimateManager()
    for _, id in ipairs({ ClimateManager.FLOAT_CLOUD_INTENSITY, ClimateManager.FLOAT_FOG_INTENSITY,
        ClimateManager.FLOAT_PRECIPITATION_INTENSITY }) do
        local float = climate:getClimateFloat(id)
        float:setEnableAdmin(true)
        float:setAdminValue(0)
    end
    if isServer() then
        climate:transmitServerStopWeather()
    else
        climate:stopWeatherAndThunder()
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

--- The map cuts the town's water off at each of `squares` ({ x, y }), as a zone of vanilla's type
--- NoWater does: IsoGridSquare.isNoWater, which reads the zones of level 0 for every storey, holds
--- on their whole columns. Returns the undo, which removes the zones.
function Fixtures.cutOffWater(squares)
    local grid, zones = getWorld():getMetaGrid(), {}
    for _, at in ipairs(squares) do
        table.insert(zones, grid:registerZone("PZHarness.cutOffWater", "NoWater", at.x, at.y, 0, 1, 1))
    end
    return function()
        for _, zone in ipairs(zones) do
            grid:removeZone(zone)
        end
    end
end

--- Gives the tile `spriteName`, and so every object of it, the property `name` (one with a value,
--- not a flag) = `value`, or none with `value` nil. Returns the undo, which puts back what the tile
--- had, none included, or nil and what is missing. A property holds only the values some tile of
--- the game gives it (TilePropertyAliasMap): any other would read back as one of those, so it is
--- missing instead.
function Fixtures.setTileProperty(spriteName, name, value)
    local sprite = getSprite(spriteName)
    if not sprite then
        return nil, "the sprite " .. tostring(spriteName)
    end
    if IsoFlagType.FromString(name) ~= IsoFlagType.MAX then
        return nil, "a tile property with a value named " .. name .. ", not a flag"
    end
    local props = sprite:getProperties()
    local saved = props:get(name)
    local function put(v)
        if v == nil then
            props:unset(name)
        else
            props:set(name, v)
        end
    end
    put(value)
    if props:get(name) ~= value then
        put(saved)
        return nil, "the value " .. tostring(value) .. " of the tile property " .. name
    end
    return function() put(saved) end
end

--- The two-sided fixtures, by name: `apply(player, args)` changes one side's copy and returns the
--- undo, or nil and what is missing (a noun phrase). The server serves each as the handler
--- "PZHarness.<name>" (ServerFixtures.lua), and TestLib makes its client setter.
Fixtures.TWO_SIDED = {
    setTime = function(_, args) return Fixtures.setTime(args.hour) end,
    setMultiplier = function(_, args) return Fixtures.setMultiplier(args.multiplier) end,
    setGrid = function(_, args) return Fixtures.setGrid(args.on) end,
    setPerk = function(player, args) return Fixtures.setPerk(player, Perks.FromString(args.perk), args.level) end,
    setInstant = function(player, args) return Fixtures.setInstant(player, args.on) end,
    setMechanicsCheat = function(player, args) return Fixtures.setMechanicsCheat(player, args.on) end,
    cutOffWater = function(_, args) return Fixtures.cutOffWater(args.squares) end,
    setTileProperty = function(_, args) return Fixtures.setTileProperty(args.sprite, args.name, args.value) end,
    -- An option in neither the mod's table nor the game's is missing rather than created.
    setSandbox = function(_, args)
        local options, name = sandboxOptions(args.table, args.key)
        if not options then
            return nil, "the sandbox option " .. tostring(args.key)
        end
        return setSandbox(options, name, args.key, args.value)
    end,
}

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

--- Every recipe the character knows, by name.
function Fixtures.knownRecipes(player)
    local names = {}
    local known = player:getKnownRecipes()
    for i = 0, known:size() - 1 do
        table.insert(names, known:get(i))
    end
    return names
end

--- The character knows (`known`) or forgets `names`; returns the undo, after which it knows
--- exactly the recipes it knew before, those learned meanwhile (a level up's AutoLearn) included,
--- which the leak check would count.
function Fixtures.knowRecipes(player, names, known)
    local saved = Fixtures.knownRecipes(player)
    if known then
        Fixtures.learnRecipes(player, names)
    else
        for _, name in ipairs(names) do
            player:getKnownRecipes():remove(name)
        end
    end
    return function()
        local list = player:getKnownRecipes()
        list:clear()
        for _, name in ipairs(saved) do
            list:add(name)
        end
    end
end

--- Whether the character knows each of `names`, by name, judged as the crafting menus judge it:
--- by the recipe, which counts its MetaRecipe, where a name alone does not (IsoGameCharacter). A
--- name with no recipe script is judged by name.
function Fixtures.knows(player, names)
    local known, scripts = {}, getScriptManager()
    for _, name in ipairs(names) do
        known[name] = player:isRecipeActuallyKnown(scripts:getCraftRecipe(name) or name)
    end
    return known
end

--- The square at `at` ({ x, y, z }, a handler's args or a handle), or nil when `at` has no x or
--- the square isn't loaded on this side.
function Fixtures.squareAt(at)
    return at and at.x and getSquare(at.x, at.y, at.z) or nil
end

--- The names of the overlays `object`'s tile shows (its attached sprites), in drawing order; none
--- for nil.
function Fixtures.overlaysOf(object)
    local names = {}
    local attached = object and object:getAttachedAnimSprite()
    for i = 0, (attached and attached:size() or 0) - 1 do
        table.insert(names, attached:get(i):getName())
    end
    return names
end

local function copyOf(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for key, field in pairs(value) do
        copy[key] = copyOf(field)
    end
    return copy
end

--- The fields `keys` of `source` (a record's SAVED_FIELDS, say), for a handler's answer. Tables are
--- copied through, so single player, where the answer never crosses the network, gets what the
--- fields held at the read, as a multiplayer client does, and not the live tables a later change
--- would rewrite. Only for plain values, as saved fields are: a table holding itself never ends.
function Fixtures.fieldsOf(source, keys)
    local fields = {}
    for _, key in ipairs(keys) do
        fields[key] = copyOf(source[key])
    end
    return fields
end

--- The name of the sprite `object` is drawn as, or nil: how the harness tells tiles apart, in its
--- fixtures and in the leak check's tokens (Snapshot) alike.
function Fixtures.spriteName(object)
    return object:getTextureName()
end

--- The first object on `square` drawn as `sprite`, or nil. Takes a nil square.
function Fixtures.objectWithSprite(square, sprite)
    local objects = square and square:getObjects()
    for i = 0, (objects and objects:size() or 0) - 1 do
        if Fixtures.spriteName(objects:get(i)) == sprite then
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

--- The def of the building nearest x, y on the ground level, within `radius` squares, that
--- `accept(def)`, if given, takes; nil if there is none.
function Fixtures.buildingNear(x, y, radius, accept)
    for r = 0, radius do
        for sx, sy in Fixtures.ring(x, y, r) do
            local square = getSquare(sx, sy, 0)
            local building = square and square:getBuilding()
            local def = building and building:getDef()
            if def and (not accept or accept(def)) then
                return def
            end
        end
    end
    return nil
end

--- The items lying on `squares` (a list), as a set of their world objects, each to its square.
function Fixtures.worldItems(squares)
    local found = {}
    for _, square in ipairs(squares) do
        local objects = square:getWorldObjects()
        for i = 0, objects:size() - 1 do
            found[objects:get(i)] = square
        end
    end
    return found
end

--- The keys of the set `now` that the set `before` lacks, as a list.
function Fixtures.newSince(before, now)
    local new = {}
    for key in pairs(now) do
        if not before[key] then
            table.insert(new, key)
        end
    end
    return new
end

--- A stand-in for an IsoRoom, to fire OnSeeNewRoom with (triggerEvent("OnSeeNewRoom", room)) as
--- the game does for a room seen for the first time (IsoCell.ProcessSpottedRooms), where the
--- authority fires it: the server, or the one game in single player. It answers what a room
--- handler asks: getName() is `name`, getSquares() an ArrayList of `squares` (a list of squares),
--- and getRandomFreeSquare() the first of `free` (a list; `squares` by default), so a test knows
--- where a spawn lands, or nil when it is empty. A handler that walks the room's squares sees only
--- `squares`: give `{}` with `free` to keep it off them.
function Fixtures.fakeRoom(name, squares, free)
    local list = ArrayList.new()
    for _, square in ipairs(squares) do
        list:add(square)
    end
    free = free or squares
    return {
        getName = function() return name end,
        getSquares = function() return list end,
        getRandomFreeSquare = function() return free[1] end,
    }
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

--- When a test last removed a vehicle, in real milliseconds (getTimestampMs), or nil: until a
--- chunk save has followed the removal, a chunk reload can bring the vehicle back (T.reloadChunk).
Fixtures.vehicleRemovedMs = nil

--- Removes what a test placed (an IsoObject or a vehicle) the way the game does, so the mods'
--- removal handlers run, and a server sends the removal to its clients: the dev mod's `remove`
--- setting first, given `player`, the character whose test placed it, if known; then vanilla's.
--- Does nothing to an object already gone from its square.
function Fixtures.removePlaced(thing, player)
    if instanceof(thing, "BaseVehicle") then
        thing:permanentlyRemove()
        Fixtures.vehicleRemovedMs = getTimestampMs()
        return
    end
    if thing:getObjectIndex() == -1 then
        return
    end
    local remove = PZHarness.testSettings.remove
    if remove and remove(thing, player) then
        return
    end
    -- Squares stay powered by a running generator that leaves them.
    if instanceof(thing, "IsoGenerator") and thing:isActivated() then
        thing:setActivated(false)
    end
    thing:getSquare():transmitRemoveItemFromSquare(thing)
end

--- Lets this side's chunks near x, y, z go of power that generators no longer there, or no longer
--- running, left behind (IsoChunk.checkForMissingGenerators), and of the generator at `going`
--- ({ x, y, z }), if given, which is about to go. A multiplayer client's switch-off of a generator
--- names it by its place on the square and can miss a copy whose square lists other objects (a
--- test's own objects come and go fast); the chunks then keep its squares powered until they load
--- again. A running generator's place is listed in every chunk its reach touches.
function Fixtures.releaseGeneratorPower(x, y, z, going)
    local size = getChunkSizeInSquares()
    local reach = math.floor(SandboxVars.GeneratorTileRange / size) + 2
    local cx, cy, cell = math.floor(x / size), math.floor(y / size), getCell()
    for wx = cx - reach, cx + reach do
        for wy = cy - reach, cy + reach do
            local chunk = cell:getChunk(wx, wy)
            if chunk then
                if going then
                    chunk:removeGeneratorPos(going.x, going.y, going.z)
                end
                chunk:checkForMissingGenerators()
            end
        end
    end
end

local function isWorkTable(object)
    return Fixtures.spriteName(object) == Fixtures.WORK_TABLE_SPRITE
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
--- setCurrentUsesFloat), `repaired` (vanilla's repair count), `modData` (keys to set). Returns the
--- item.
function Fixtures.changeItem(item, changes)
    if changes.condition then
        item:setCondition(changes.condition)
    end
    if changes.uses then
        item:setCurrentUsesFloat(changes.uses)
    end
    if changes.repaired then
        item:setHaveBeenRepaired(changes.repaired)
    end
    for key, value in pairs(changes.modData or {}) do
        item:getModData()[key] = value
    end
    return item
end

return Fixtures
