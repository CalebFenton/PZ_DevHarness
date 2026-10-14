require "PZHarness/ServerHandlers"
require "PZHarness/Fixtures"
require "PZHarness/Snapshot"

-- Development only, not published. The server's half of the test library's two-sided fixtures
-- (client/PZHarness/TestLib.lua): on a multiplayer client a fixture changes the client's copy and
-- calls one of these handlers for the server's, which the server undoes when the test ends. Single
-- player changes its one copy on the client side and calls only the handlers that make or track
-- things ("PZHarness.give", "PZHarness.dress", "PZHarness.count", "PZHarness.tile",
-- "PZHarness.bench", "PZHarness.trackPlaced"), which work the same in both. Names start with
-- "PZHarness." so they never meet a dev mod's. The dev mod's hooks (`sandboxChanged`, `remove`,
-- `spawnVehicle`) come from PZHarness.registerTests (shared/PZHarness/Fixtures.lua), as the
-- client's do.

PZHarness = PZHarness or {}

local Fixtures = PZHarness.Fixtures
local handler = PZHarness.serverHandler

local function sandboxChanged()
    if PZHarness.testSettings.sandboxChanged then
        PZHarness.testSettings.sandboxChanged()
    end
end

-- Removes `object` when the calling test ends, as T.track does.
local function track(defer, object)
    defer(function() Fixtures.removePlaced(object) end)
end

-- T.placeTile: a tile object of `args.sprite` with `args.modData` on the square at x, y, z.
handler("PZHarness.tile", function(_, args, defer)
    local square = getSquare(args.x, args.y, args.z)
    if not square then
        return nil, "a loaded square for a " .. tostring(args.sprite)
    end
    track(defer, Fixtures.newTile(square, args.sprite, args.modData))
    return {}
end)

-- T.placeBench: a workstation of the entity script `args.entity`, drawn as `args.sprite`, on the
-- square at x, y, z, which the character is using as its crafting window makes them.
handler("PZHarness.bench", function(player, args, defer)
    local square = getSquare(args.x, args.y, args.z)
    if not square then
        return nil, "a loaded square for a " .. args.entity
    end
    local bench, missing = Fixtures.newBench(square, args.entity, args.sprite, player)
    if bench then
        track(defer, bench)
    end
    if missing then
        return nil, missing
    end
    return {}
end)

-- T.placeAsPlayer: the object drawn as `args.sprite` on the square at x, y, z, which the character
-- placed with the moveables action, goes when the test ends.
handler("PZHarness.trackPlaced", function(_, args, defer)
    local object = Fixtures.objectWithSprite(getSquare(args.x, args.y, args.z), args.sprite)
    if not object then
        return nil, "the placed " .. tostring(args.sprite) .. " on the server"
    end
    track(defer, object)
    return {}
end)

-- How far from the square a vehicle entered the world on its key may land (BaseVehicle.addKeyToSquare).
local KEY_REACH = 10

-- Whether `item` is a key with `keyId`, or a key ring holding one.
local function isKeyTo(item, keyId)
    if item:IsInventoryContainer() then
        local inside = item:getInventory():getItems()
        for i = 0, inside:size() - 1 do
            if isKeyTo(inside:get(i), keyId) then
                return true
            end
        end
        return false
    end
    return item:getKeyId() == keyId
end

-- Takes away the key a vehicle got as it entered the world on `square`. addVehicleDebug adds it
-- to the world at once (BaseVehicle.addToWorld, trySpawnKey), so nothing can stop it: in the
-- ignition or the glove box it goes with the vehicle, but it may also lie on a square near it or
-- in a container there, alone or on a key ring.
local function removeVehicleKey(vehicle, square)
    local keyId = vehicle:getKeyId()
    for x = square:getX() - KEY_REACH, square:getX() + KEY_REACH do
        for y = square:getY() - KEY_REACH, square:getY() + KEY_REACH do
            local near = getSquare(x, y, square:getZ())
            local worldObjects = near and near:getWorldObjects()
            for i = (worldObjects and worldObjects:size() or 0) - 1, 0, -1 do
                local object = worldObjects:get(i)
                if isKeyTo(object:getItem(), keyId) then
                    if isServer() then
                        near:transmitRemoveItemFromSquare(object)
                    end
                    near:removeWorldObject(object)
                end
            end
            local objects = near and near:getObjects()
            for i = 0, (objects and objects:size() or 0) - 1 do
                local container = objects:get(i):getContainer()
                local items = container and container:getItems()
                for j = (items and items:size() or 0) - 1, 0, -1 do
                    local item = items:get(j)
                    if isKeyTo(item, keyId) then
                        container:Remove(item)
                        sendRemoveItemFromContainer(container, item)
                    end
                end
            end
        end
    end
end

-- T.placeVehicle: a vehicle of `args.script` facing `args.facing` ("N" unless given) on the first
-- of `args.squares` (each { x, y, z }) that takes it, made by the dev mod's `spawnVehicle(script,
-- square, facing, args.args)` setting if that returns one, else by addVehicleDebug.
-- addVehicleDebug returns a vehicle even where it leaves it out of the world, as where it would
-- hit another vehicle; only a vehicle in the world gets an id (BaseVehicle.createPhysics). The
-- server sends it to the clients nearby, by the same id.
handler("PZHarness.vehicle", function(_, args, defer)
    local facing = args.facing or "N"
    local spawn = PZHarness.testSettings.spawnVehicle
    for _, at in ipairs(args.squares or {}) do
        local square = getSquare(at.x, at.y, at.z)
        local vehicle = square and spawn and spawn(args.script, square, facing, args.args)
        if square and not vehicle then
            vehicle = addVehicleDebug(args.script, IsoDirections[facing], nil, square)
        end
        if vehicle and vehicle:getId() ~= -1 then
            defer(function()
                Fixtures.removePlaced(vehicle)
                removeVehicleKey(vehicle, square)
            end)
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

handler("PZHarness.setMechanicsCheat", function(player, args, defer)
    defer(Fixtures.setMechanicsCheat(player, args.on))
    return {}
end)

-- The levels the client had, without undo: the scenario's setup reaching the server.
handler("PZHarness.setPerkLevels", function(player, args)
    Fixtures.setPerkLevels(player, args.levels)
    return {}
end)

-- The runner's restore of the `perks` setting (`args.perks`, perk ids): the levels the server's
-- copy has now, whatever the client's copy shows, which the server's perk sync (PlayerXpPacket)
-- can leave a level behind for up to a second.
handler("PZHarness.keepPerkLevels", function(player, args, defer)
    local levels = {}
    for _, id in ipairs(args.perks) do
        local perk = Perks.FromString(id)
        if perk and perk ~= Perks.MAX then
            levels[id] = player:getPerkLevel(perk)
        end
    end
    defer(function() Fixtures.setPerkLevels(player, levels) end)
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

-- The runner's leak check, on the server's copy (client/PZHarness/Leaks.lua): the last snapshot
-- each client asked for, which the next one is compared with.
local baselines = {}

-- Snapshots the server's copy around `args` (x, y, z, radius, levels, ignore) and the caller's
-- character, compares it with the last one (none after `args.fresh`) and keeps it for the next.
-- Answers with what changed (`leaks`, lines) and, as a flat list of key and signature pairs
-- (`changed`), the squares that changed, for the client to compare with its copy. With
-- `args.peek`, a list of square keys, it only answers with their signatures now (`sigs`), for
-- the client's second look at squares where the two copies differed.
handler("PZHarness.snapshot", function(player, args)
    local Snapshot = PZHarness.Snapshot
    if args.peek then
        local sigs = {}
        for _, key in ipairs(args.peek) do
            table.insert(sigs, key)
            table.insert(sigs, Snapshot.signatureAt(key, args.ignore))
        end
        return { sigs = sigs }
    end
    local snapshot = Snapshot.take(args, player)
    local owner = player:getUsername()
    local baseline = not args.fresh and baselines[owner] or nil
    baselines[owner] = snapshot
    if not baseline then
        return { leaks = {}, changed = {} }
    end
    local report = Snapshot.diff(baseline, snapshot)
    local changed = {}
    for _, key in ipairs(report.changed) do
        table.insert(changed, key)
        table.insert(changed, snapshot.squares[key])
    end
    return { leaks = Snapshot.addLines({}, report), changed = changed }
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
