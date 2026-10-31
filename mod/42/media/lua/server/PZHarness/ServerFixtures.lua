require "PZHarness/ServerHandlers"
require "PZHarness/Fixtures"
require "PZHarness/Snapshot"
require "PZHarness/Rolls"

-- Development only, not published. The server half of the test library's two-sided fixtures
-- (client/PZHarness/TestLib.lua): on a multiplayer client a fixture changes the client's copy and
-- calls one of these handlers for the server's, which the server undoes when the test ends. Single
-- player changes its one copy client-side and calls only the handlers that make or track things.
-- Names start with "PZHarness." so they never collide with a dev mod's.

PZHarness = PZHarness or {}

local Fixtures = PZHarness.Fixtures
local handler, need = PZHarness.serverHandler, PZHarness.need

-- The two-sided fixtures (Fixtures.TWO_SIDED).
for name in pairs(Fixtures.TWO_SIDED) do
    handler("PZHarness." .. name, function(player, args, defer)
        local undo, missing = Fixtures.TWO_SIDED[name](player, args)
        defer(need(undo, "the server's " .. tostring(missing)))
        return {}
    end)
end

-- Removes `object` when the calling test ends, as T.track does, for `player`'s test.
local function track(defer, object, player)
    defer(function() Fixtures.removePlaced(object, player) end)
end

--- The loaded square at `at` ({ x, y, z }), or the running handler ends as missing it.
function PZHarness.squareAt(at)
    return need(Fixtures.squareAt(at), "the square " .. tostring(at and at.x) .. "," .. tostring(at and at.y) .. ","
        .. tostring(at and at.z) .. " loaded on the server")
end

--- The vehicle `at` names ({ id, x, y, z } of a T.placeVehicle handle; single player finds it by
--- the squares around x, y, z), or the running handler ends as missing it when there is none or it
--- has been taken out of the world.
function PZHarness.vehicleAt(at)
    local vehicle = at and Fixtures.vehicleById(at.id, at)
    return need(vehicle and not vehicle:isRemovedFromWorld() and vehicle,
        "vehicle " .. tostring(at and at.id) .. " on the server")
end

-- The wooden floor a player lays upstairs.
local FLOOR = "carpentry_02_58"

--- The square at `at` ({ x, y, z }), made where there is none, as on a level above open ground,
--- whose square only comes to be with what stands there; with `withFloor`, on a floor laid for it
--- if it has none, taken away when the test ends. Vanilla's addFloor rechecks the roof below it
--- (IsoCell.checkHaveRoof), which takes the square below's exterior flag away, and the undo checks
--- it again. The running handler ends as missing a square it can't make.
function PZHarness.squareFor(at, defer, withFloor)
    local square = need(Fixtures.squareAt(at) or getCell():createNewGridSquare(at.x, at.y, at.z, true),
        "a square at " .. at.x .. "," .. at.y .. "," .. at.z)
    if withFloor and not square:getFloor() then
        local floor = square:addFloor(FLOOR)
        defer(function()
            Fixtures.removePlaced(floor)
            getCell():checkHaveRoof(at.x, at.y)
        end)
    end
    return square
end

-- T.placeTile: a tile object of `args.sprite` with `args.modData` on the square at x, y, z.
handler("PZHarness.tile", function(player, args, defer)
    local square = need(getSquare(args.x, args.y, args.z), "a loaded square for a " .. tostring(args.sprite))
    track(defer, Fixtures.newTile(square, args.sprite, args.modData), player)
    return {}
end)

-- T.placeBench: a workstation of the entity script `args.entity`, drawn as `args.sprite`, on the
-- square at x, y, z, which the character is using as its crafting window makes them.
handler("PZHarness.bench", function(player, args, defer)
    local square = need(getSquare(args.x, args.y, args.z), "a loaded square for a " .. args.entity)
    local bench, missing = Fixtures.newBench(square, args.entity, args.sprite, player)
    if bench then
        track(defer, bench, player)
    end
    need(not missing, missing)
    return {}
end)

-- T.placeAsPlayer: the object drawn as `args.sprite` on the square at x, y, z, which the character
-- placed with the moveables action, goes when the test ends.
handler("PZHarness.trackPlaced", function(player, args, defer)
    track(defer, need(Fixtures.objectWithSprite(getSquare(args.x, args.y, args.z), args.sprite),
        "the placed " .. tostring(args.sprite) .. " on the server"), player)
    return {}
end)

-- What an object on a square is drawn as, to tell it from the others there.
local function lookOf(object)
    local sprite = object:getSprite()
    return sprite and sprite:getName() or object:getObjectName()
end

--- Has what stands on the square at `at` ({ x, y, z }) when the test ends, and didn't now, go then
--- (Fixtures.removePlaced, for `player`), however it came: a build, a job, an OnCreate that swapped
--- the object, a chunk that loaded again with a new copy. Counted by look rather than by object, so
--- it finds those. The running handler ends as missing an unloaded square.
function PZHarness.trackSquare(defer, player, at)
    local left = {}
    local objects = PZHarness.squareAt(at):getObjects()
    for i = 0, objects:size() - 1 do
        local look = lookOf(objects:get(i))
        left[look] = (left[look] or 0) + 1
    end
    defer(function()
        local square = Fixtures.squareAt(at)
        local new, now = {}, square and square:getObjects()
        for i = 0, (now and now:size() or 0) - 1 do
            local object = now:get(i)
            local look = lookOf(object)
            if (left[look] or 0) > 0 then
                left[look] = left[look] - 1
            else
                table.insert(new, object)
            end
        end
        for i = #new, 1, -1 do
            Fixtures.removePlaced(new[i], player)
        end
    end)
end

-- T.trackSquare.
handler("PZHarness.trackSquare", function(player, args, defer)
    PZHarness.trackSquare(defer, player, args)
    return {}
end)

-- T.floorAbove: a wooden floor one level above the square at x, y, z, as a player roofs a yard
-- (PZHarness.squareFor). Answers whether the square below is still outdoors.
handler("PZHarness.floorAbove", function(_, args, defer)
    PZHarness.squareFor({ x = args.x, y = args.y, z = args.z + 1 }, defer, true)
    return { outside = PZHarness.squareAt(args):isOutside() }
end)

-- T.ringOfTiles: a tile of `args.sprite` on each of the eight squares around x, y on level
-- `args.level`, the squares made where that level has none, as building upstairs makes them.
-- Answers how many went down.
handler("PZHarness.ringOfTiles", function(player, args, defer)
    local placed = 0
    for dx = -1, 1 do
        for dy = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
                local x, y = args.x + dx, args.y + dy
                local square = getSquare(x, y, args.level) or getCell():createNewGridSquare(x, y, args.level, true)
                if square then
                    track(defer, Fixtures.newTile(square, args.sprite), player)
                    placed = placed + 1
                end
            end
        end
    end
    return { placed = placed }
end)

-- T.floorItem: an `args.type` holding `args.uses` (its share of full) dropped on the floor of the
-- square at x, y, z, as a player dropping it does, for everyone to see.
handler("PZHarness.floorItem", function(player, args, defer)
    local square = PZHarness.squareAt(args)
    local item = need(instanceItem(args.type), "an item " .. tostring(args.type))
    if args.uses then
        item:setCurrentUsesFloat(args.uses)
    end
    square:AddWorldInventoryItem(item, 0.5, 0.5, 0)
    defer(function()
        local world = item:getWorldItem()
        if world then
            Fixtures.removePlaced(world, player)
        end
    end)
    return {}
end)

-- T.takeFloorItems: the items lying on the squares `args.squares` ({ x, y, z } each) taken off the
-- floor, as a player picking them up leaves none behind, and answered as { { type, uses, modData
-- } }: uses for drainable items, modData's plain values.
handler("PZHarness.takeFloorItems", function(player, args)
    local items = {}
    for _, at in ipairs(args.squares or {}) do
        local objects = PZHarness.squareAt(at):getWorldObjects()
        for i = objects:size() - 1, 0, -1 do
            local object = objects:get(i)
            local item = object:getItem()
            local modData = {}
            for key, value in pairs(item:getModData()) do
                if type(value) ~= "table" then
                    modData[key] = value
                end
            end
            table.insert(items, { type = item:getFullType(), modData = modData,
                uses = instanceof(item, "DrainableComboItem") and item:getCurrentUsesFloat() or nil })
            Fixtures.removePlaced(object, player)
        end
    end
    return { items = items }
end)

-- The modData key `args.key` of the object drawn as `args.sprite` on the square at x, y, z.
handler("PZHarness.objectModData", function(_, args)
    local object = need(Fixtures.objectWithSprite(PZHarness.squareAt(args), args.sprite),
        "a " .. tostring(args.sprite) .. " on the server")
    return { value = object:getModData()[args.key] }
end)

-- The world updates the authority has run (`frame`). A server serves commands between its updates
-- (GameServer.main), and single player within one, after the objects' (IsoCell.update), so once
-- the count passes an earlier answer's, every object has had an update since that answer, and a
-- step queued after the wait for it comes after that update's OnTick too.
handler("PZHarness.worldFrame", function()
    return { frame = getWorld():getFrameNo() }
end)

-- T.forceRoll: the mod's roll gives `args.rolls` until the test ends (PZHarness.Rolls.force).
handler("PZHarness.forceRoll", function(_, args, defer)
    PZHarness.Rolls.force(defer, args.rolls)
    return {}
end)

-- T.setStat: the character's stat `args.stat` (a CharacterStat field name) at `args.value` on the
-- authority, sent to its client, until the test ends.
handler("PZHarness.setStat", function(player, args, defer)
    local stat = need(CharacterStat[args.stat], "the character stat " .. tostring(args.stat))
    local stats = player:getStats()
    local function set(value)
        stats:set(stat, value)
        if isServer() then
            syncPlayerStats(player, SyncPlayerStatsPacket.getBitMaskForStat(stat))
        end
    end
    local before = stats:get(stat)
    set(args.value)
    defer(function() set(before) end)
    return {}
end)

-- T.takeItems: the character's items of `args.ids`, and all of type `args.type`, bags included,
-- taken away as the server takes an item, which the client then loses too. Answers how many.
handler("PZHarness.takeItems", function(player, args)
    local inventory = player:getInventory()
    local items = {}
    for _, id in ipairs(args.ids or {}) do
        table.insert(items, need(inventory:getItemWithIDRecursiv(id), "the server's copy of item " .. tostring(id)))
    end
    if args.type then
        local all = inventory:getAllTypeRecurse(args.type)
        for i = 0, all:size() - 1 do
            table.insert(items, all:get(i))
        end
    end
    for _, item in ipairs(items) do
        local container = item:getContainer()
        container:Remove(item)
        sendRemoveItemFromContainer(container, item)
    end
    return { taken = #items }
end)

-- T.xpAward: what the game gives the character for an award of `args.xp` in the perk `args.perk`
-- (a Perks field name), through the AddXP call CraftRecipe.addXP makes outside a server. Answers
-- the XP `gained`.
handler("PZHarness.xpAward", function(player, args)
    local perk, xp = need(Perks[args.perk], "the perk " .. tostring(args.perk)), player:getXp()
    local before = xp:getXP(perk)
    xp:AddXP(perk, args.xp, true, true, false, false)
    return { gained = xp:getXP(perk) - before }
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
-- square, facing, args.args, defer)` setting if that returns one, else by addVehicleDebug.
-- addVehicleDebug returns a vehicle even where it leaves it out of the world, as where it would
-- hit another vehicle; only a vehicle in the world gets an id (BaseVehicle.createPhysics). The
-- server sends it to the clients nearby, by the same id.
handler("PZHarness.vehicle", function(_, args, defer)
    local facing = args.facing or "N"
    local spawn = PZHarness.testSettings.spawnVehicle
    for _, at in ipairs(args.squares or {}) do
        local square = getSquare(at.x, at.y, at.z)
        local vehicle = square and spawn and spawn(args.script, square, facing, args.args, defer)
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
    need(nil, "open ground for a " .. tostring(args.script))
end)

-- The runner's clear sky for a multiplayer run, which the server sends to its clients.
handler("PZHarness.clearWeather", function()
    Fixtures.clearWeather()
    return {}
end)

-- The levels the client had, without undo: the scenario's setup reaching the server.
handler("PZHarness.setPerkLevels", function(player, args)
    Fixtures.setPerkLevels(player, args.levels)
    return {}
end)

-- The runner's restore of the `perks` setting (`args.perks`, perk ids): the server copy's current
-- levels, which the client's copy may lag (PlayerXpPacket). Answers them in `levels`, for the
-- client's restore.
handler("PZHarness.keepPerkLevels", function(player, args, defer)
    local levels = {}
    for _, id in ipairs(args.perks) do
        local perk = Perks.FromString(id)
        if perk and perk ~= Perks.MAX then
            levels[id] = player:getPerkLevel(perk)
        end
    end
    defer(function() Fixtures.setPerkLevels(player, levels) end)
    return { levels = levels }
end)

-- Not undone, as on the client.
handler("PZHarness.learnRecipes", function(player, args)
    Fixtures.learnRecipes(player, args.names)
    return {}
end)

-- Not undone, as on the client: scenarios place it too, and a table left standing harms no test.
handler("PZHarness.workTable", function(player)
    local object = need(Fixtures.placeWorkTable(player), "a free square next to the character for a work table")
    local square = object:getSquare()
    return { x = square:getX(), y = square:getY(), z = square:getZ() }
end)

-- The runner's reset before every test, on the server's copy.
handler("PZHarness.reset", function(player)
    Fixtures.resetCharacter(player)
    return {}
end)

-- T.goNextTo: the server's copy of the character to the middle of the square its client just
-- teleported to.
handler("PZHarness.moveTo", function(player, args)
    Fixtures.teleportToMiddle(player, args.x, args.y, args.z)
    return {}
end)

handler("PZHarness.changeItem", function(player, args)
    local item = need(player:getInventory():getItemById(args.id), "the server's copy of item " .. tostring(args.id))
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

-- T.give: `args.items`, a list of { type, count, uses, condition, repaired, modData, worn, equip }.
handler("PZHarness.give", function(player, args)
    local given = {}
    for _, spec in ipairs(args.items or {}) do
        for _ = 1, spec.count or 1 do
            local item = need(instanceItem(spec.type), "an item of type " .. tostring(spec.type))
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
        local item = need(inventory:getItemById(entry.id), "the server's copy of given item " .. tostring(entry.id))
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
