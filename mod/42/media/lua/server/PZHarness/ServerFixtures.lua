require "PZHarness/ServerHandlers"
require "PZHarness/Fixtures"

-- Development only, not published. The server's half of the test library's two-sided fixtures
-- (client/PZHarness/TestLib.lua): on a multiplayer client a fixture changes the client's copy and
-- calls one of these handlers for the server's, which the server undoes when the test ends. Single
-- player changes its one copy on the client side and calls only the handlers that make things
-- ("PZHarness.give", "PZHarness.dress", "PZHarness.count", "PZHarness.tile", "PZHarness.bench"),
-- which work the same in both. Names start with "PZHarness." so they never meet a dev mod's.
--
-- A dev mod's server Lua may set, in `PZHarness.serverSettings`:
-- - `sandboxChanged()`: called after the server's copy of a sandbox option is set or restored,
--   as the `tests.sandboxChanged` setting is on the client.
-- - `remove(object)`: removes a placed object of the mod the way the mod does, returning true, as
--   the `tests.remove` setting does for T.track; for the objects T.placeTile and T.placeBench
--   place, in single player too.
-- - `spawnVehicle(script, square, facing, args)`: makes the vehicles T.placeVehicle asks for, with
--   the test's `opts.args`, returning one, or nil to leave it to addVehicleDebug.

PZHarness = PZHarness or {}
PZHarness.serverSettings = PZHarness.serverSettings or {}

local Fixtures = PZHarness.Fixtures
local handler = PZHarness.serverHandler

local function sandboxChanged()
    if PZHarness.serverSettings.sandboxChanged then
        PZHarness.serverSettings.sandboxChanged()
    end
end

-- Removes `object` when the calling test ends the way T.track does, which a server sends to its
-- clients.
local function track(defer, object)
    defer(function()
        if object:getObjectIndex() == -1 then
            return
        end
        local remove = PZHarness.serverSettings.remove
        if remove and remove(object) then
            return
        end
        -- Squares stay powered by a running generator that leaves them.
        if instanceof(object, "IsoGenerator") and object:isActivated() then
            object:setActivated(false)
        end
        object:getSquare():transmitRemoveItemFromSquare(object)
    end)
end

-- Adds `object` to its square and sends it to the clients when this is a server.
local function addToSquare(square, object)
    square:AddTileObject(object)
    if isServer() then
        object:transmitCompleteItemToClients()
    end
end

-- T.placeTile: a tile object of `args.sprite` with `args.modData` on the square at x, y, z.
handler("PZHarness.tile", function(_, args, defer)
    local square = getSquare(args.x, args.y, args.z)
    if not square then
        return nil, "a loaded square for a " .. tostring(args.sprite)
    end
    local object = IsoObject.new(square, args.sprite, "PZHarness")
    for key, value in pairs(args.modData or {}) do
        object:getModData()[key] = value
    end
    addToSquare(square, object)
    track(defer, object)
    return {}
end)

-- T.placeBench: a workstation of the entity script `args.entity`, drawn as `args.sprite`, on the
-- square at x, y, z, which the character is using as its crafting window makes them.
handler("PZHarness.bench", function(player, args, defer)
    local script = getScriptManager():getGameEntityScript(args.entity)
    if not script then
        return nil, "the entity script " .. tostring(args.entity)
    end
    local square = getSquare(args.x, args.y, args.z)
    if not square then
        return nil, "a loaded square for a " .. args.entity
    end
    local bench = IsoObject.new(square, args.sprite, args.entity)
    GameEntityFactory.CreateIsoObjectEntity(bench, script, true)
    addToSquare(square, bench)
    track(defer, bench)
    if not bench:getComponent(ComponentType.CraftBench) then
        return nil, "a craft bench in " .. args.entity
    end
    bench:setUsingPlayer(player)
    return {}
end)

-- T.placeVehicle: a vehicle of `args.script` facing `args.facing` ("N" unless given) on the first
-- of `args.squares` (each { x, y, z }) that takes it, made by the dev mod's
-- `PZHarness.serverSettings.spawnVehicle(script, square, facing, args.args)` if that returns one,
-- else by addVehicleDebug. addVehicleDebug returns a vehicle even where it leaves it out of the
-- world, as where it would hit another vehicle; only a vehicle in the world gets an id
-- (BaseVehicle.createPhysics). The server sends it to the clients nearby, by the same id.
handler("PZHarness.vehicle", function(_, args, defer)
    local facing = args.facing or "N"
    local spawn = PZHarness.serverSettings.spawnVehicle
    for _, at in ipairs(args.squares or {}) do
        local square = getSquare(at.x, at.y, at.z)
        local vehicle = square and spawn and spawn(args.script, square, facing, args.args)
        if square and not vehicle then
            vehicle = addVehicleDebug(args.script, IsoDirections[facing], nil, square)
        end
        if vehicle and vehicle:getId() ~= -1 then
            defer(function() vehicle:permanentlyRemove() end)
            return { id = vehicle:getId(), x = at.x, y = at.y, z = at.z }
        end
    end
    return nil, "open ground for a " .. tostring(args.script)
end)

handler("PZHarness.setSandbox", function(_, args, defer)
    local options = Fixtures.sandboxOptions(args.table, args.key)
    if not options then
        return nil, "the server's sandbox option " .. tostring(args.key)
    end
    defer(Fixtures.setSandbox(options, args.key, args.value, sandboxChanged))
    return {}
end)

handler("PZHarness.setTime", function(_, args, defer)
    defer(Fixtures.setTime(args.hour))
    return {}
end)

handler("PZHarness.setMultiplier", function(_, args, defer)
    defer(Fixtures.setMultiplier(args.multiplier))
    return {}
end)

handler("PZHarness.setGrid", function(_, args, defer)
    defer(Fixtures.setGrid(args.on))
    return {}
end)

handler("PZHarness.setPerk", function(player, args, defer)
    defer(Fixtures.setPerk(player, Perks.FromString(args.perk), args.level))
    return {}
end)

handler("PZHarness.setInstant", function(player, args, defer)
    defer(Fixtures.setInstant(player, args.on))
    return {}
end)

-- The levels the client had, without undo: the runner's restore of the `perks` setting, and the
-- scenario's setup reaching the server.
handler("PZHarness.setPerkLevels", function(player, args)
    Fixtures.setPerkLevels(player, args.levels)
    return {}
end)

-- Not undone, as on the client.
handler("PZHarness.learnRecipes", function(player, args)
    Fixtures.learnRecipes(player, args.names)
    return {}
end)

handler("PZHarness.forgetRecipes", function(player, args)
    Fixtures.forgetRecipes(player, args.names)
    return {}
end)

-- Not undone, as on the client: scenarios place it too, and a table left standing harms no test.
handler("PZHarness.workTable", function(player)
    local object = Fixtures.placeWorkTable(player)
    if not object then
        return nil, "a free square next to the character for a work table"
    end
    local square = object:getSquare()
    return { x = square:getX(), y = square:getY(), z = square:getZ() }
end)

-- The runner's reset before every test, on the server's copy.
handler("PZHarness.reset", function(player)
    Fixtures.resetCharacter(player)
    return {}
end)

handler("PZHarness.changeItem", function(player, args)
    local item = player:getInventory():getItemById(args.id)
    if not item then
        return nil, "the server's copy of item " .. tostring(args.id)
    end
    Fixtures.changeItem(item, args.changes)
    item:syncItemFields()
    return {}
end)

--- Adds `item`, fully set up, to the character's inventory and sends it to the client. Returns the
--- entry a handler lists in its reply's `given`, which T.server waits for: `opts.worn` puts the
--- item on and `opts.equip` ("primary", "secondary" or "both") in the hands once the client has it,
--- through "PZHarness.dress".
function PZHarness.giveItem(player, item, opts)
    opts = opts or {}
    local inventory = player:getInventory()
    inventory:AddItem(item)
    sendAddItemToContainer(inventory, item)
    return { id = item:getID(), worn = opts.worn or nil, equip = opts.equip }
end

-- T.give: `args.items`, a list of { type, count, uses, condition, modData, worn, equip }.
handler("PZHarness.give", function(player, args)
    local given = {}
    for _, spec in ipairs(args.items or {}) do
        for _ = 1, spec.count or 1 do
            local item = instanceItem(spec.type)
            if not item then
                return nil, "an item of type " .. tostring(spec.type)
            end
            Fixtures.changeItem(item, spec)
            table.insert(given, PZHarness.giveItem(player, item, spec))
        end
    end
    return { given = given }
end)

-- Puts on and takes in hand what "PZHarness.give" or a dev mod's handler gave, once the client has
-- it: clothing synced before the item itself would reach the client as a stray copy
-- (SyncClothingPacket creates an item it can't find), since the two travel on different ordered
-- channels. Fires OnClothingUpdated after putting something on, as wearing it does.
handler("PZHarness.dress", function(player, args)
    local inventory = player:getInventory()
    local worn, equipped = false, false
    for _, entry in ipairs(args.given or {}) do
        local item = inventory:getItemById(entry.id)
        if not item then
            return nil, "the server's copy of given item " .. tostring(entry.id)
        end
        if entry.worn then
            player:setWornItem(item:getBodyLocation(), item)
            worn = true
        end
        if entry.equip == "primary" or entry.equip == "both" then
            player:setPrimaryHandItem(item)
            equipped = true
        end
        if entry.equip == "secondary" or entry.equip == "both" then
            player:setSecondaryHandItem(item)
            equipped = true
        end
    end
    if worn then
        syncVisuals(player)
        triggerEvent("OnClothingUpdated", player)
    end
    if equipped then
        sendEquip(player)
    end
    return {}
end)

-- How many of each of `args.types` the character carries, in bags too, and with `args.dropped`
-- also those dropped on the squares around them, which then go away: a craft whose output doesn't
-- fit drops it at the character's feet (Actions.addOrDropItem).
handler("PZHarness.count", function(player, args)
    local counts = {}
    local here = args.dropped and player:getCurrentSquare()
    for _, fullType in ipairs(args.types or {}) do
        local count = player:getInventory():getCountTypeRecurse(fullType)
        for dx = -1, 1 do
            for dy = -1, 1 do
                local square = here and getSquare(here:getX() + dx, here:getY() + dy, here:getZ())
                local objects = square and square:getWorldObjects()
                for i = (objects and objects:size() or 0) - 1, 0, -1 do
                    local object = objects:get(i)
                    if object:getItem():getFullType() == fullType then
                        count = count + 1
                        if isServer() then
                            square:transmitRemoveItemFromSquare(object)
                        end
                        square:removeWorldObject(object)
                    end
                end
            end
        end
        counts[fullType] = count
    end
    return { counts = counts }
end)
