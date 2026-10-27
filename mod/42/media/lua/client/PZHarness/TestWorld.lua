require "PZHarness/TestLib"
require "PZHarness/TestReads"
require "Moveables/ISMoveableSpriteProps"
require "Moveables/ISMoveablesAction"
local Runtime = require "PZHarness/TestRuntime"

-- World fixtures: square reservations, authoritative placement and player moveables actions.
-- The runtime owns their waits and server calls; each fixture owns finding its client copy.
local T = PZHarness.Test
local SEARCH_RADIUS = T.SEARCH_RADIUS
local VEHICLE_TRIES = 8
local RECEIVE_MS = 15000

-- Squares

local function squareOf(near)
    if type(near) == "table" then near = near.square end
    if not near then
        return T.player():getCurrentSquare()
    end
    return instanceof(near, "IsoGridSquare") and near or near:getSquare()
end

local function isFreeSquare(square, indoors)
    if PZHarness.testSettings.isFreeSquare then
        return PZHarness.testSettings.isFreeSquare(square, indoors)
    end
    return square:isFree(false) and square:getVehicleContainer() == nil and square:isOutside() ~= indoors
end

-- Up to `count` free squares; see T.squares.
local function freeSquares(self, count, opts)
    local center = squareOf(opts.near)
    local found = {}
    if not center or count < 1 then return found end
    local z = center:getZ()
    for radius = opts.minDistance or 1, SEARCH_RADIUS do
        for x, y in PZHarness.Fixtures.ring(center:getX(), center:getY(), radius) do
            local square = getSquare(x, y, z)
            if square and not self.used[square]
                and isFreeSquare(square, opts.indoors == true)
                and (not opts.bare or square:getObjects():size() == 1)
                and (not opts.accept or opts.accept(square)) then
                self.used[square] = true
                table.insert(found, square)
                if #found == count then
                    return found
                end
            end
        end
    end
    return found
end

--- `count` free squares (the `isFreeSquare` setting) around `opts.near` (a square or object; the
--- character's square by default), nearest first and at least `opts.minDistance` tiles away:
--- indoors when `opts.indoors`, else outdoors; holding only their floor when `opts.bare`; and
--- those `opts.accept(square)` takes, if given. Each square goes to one fixture per test. Nil
--- unless all are found.
function T.squares(self, count, opts)
    local found = freeSquares(self, count, opts or {})
    return #found == count and found or nil
end

--- One reserved square, or nil and missing `what`; options are T.squares's, including handles
--- as `near`. The caller's options are read, never copied or changed.
function T.square(self, opts, what)
    local found = T.need(self, T.squares(self, 1, opts), what)
    return found and found[1]
end

--- A fixture handle of `square`. Handles are this shape throughout: the square's x, y, z and
--- square, and as a fixture fills them in, `kind` (a `records` kind or job feature), `sprite` and
--- `object`, this client's copy (T.copyOf).
function T.where(square)
    return { x = square:getX(), y = square:getY(), z = square:getZ(), square = square }
end

--- This client's copy of what the handle `handle` names on its square: the object drawn as
--- `sprite`, else as handle.sprite, else of the record kind handle.kind (its owner's
--- feature.isObject, the `records` test setting); or nil.
function T.copyOf(handle, sprite)
    local square = getSquare(handle.x, handle.y, handle.z)
    sprite = sprite or handle.sprite
    if sprite then
        return T.objectWithSprite(square, sprite)
    end
    local records = PZHarness.testSettings.records
    local isObject = records and records[handle.kind] and records[handle.kind].owner().feature.isObject
    local objects = isObject and square and square:getObjects()
    for i = 0, (objects and objects:size() or 0) - 1 do
        if isObject(objects:get(i)) then
            return objects:get(i)
        end
    end
    return nil
end

--- Plain coordinates of a handle or square, with the server arguments in `fields`.
function T.at(near, fields)
    local at
    if type(near) == "table" and near.x then
        at = { x = near.x, y = near.y, z = near.z }
    else
        local square = type(near) == "table" and near.square or near
        at = { x = square:getX(), y = square:getY(), z = square:getZ() }
    end
    for key, value in pairs(fields or {}) do at[key] = value end
    return at
end

-- Fixtures

--- Removes `thing` (an IsoObject or a vehicle) when the test ends, the way the game does, so the
--- mods' removal handlers run (PZHarness.Fixtures.removePlaced). Returns `thing`.
function T.track(self, thing)
    T.defer(self, function() PZHarness.Fixtures.removePlaced(thing, T.player()) end)
    return thing
end

--- Queues removing, when the test ends, what then stands on `at`'s square (a handle or square)
--- that doesn't now, the way the game removes it (PZHarness.trackSquare): for what a test
--- puts there by other means than a fixture, such as a job, whatever its OnCreate swapped in.
function T.trackSquare(self, at)
    T.server(self, "PZHarness.trackSquare", T.at(at))
end

--- Queues an `fullType` holding `uses` (its share of full; as made if nil) dropped on the floor of
--- `at`'s square (a handle or square) by the authority, as a player drops it, for everyone to see.
--- It goes when the test ends.
function T.floorItem(self, at, fullType, uses)
    T.server(self, "PZHarness.floorItem", T.at(at, { type = fullType, uses = uses }))
end

--- Queues the authority taking the items lying on `squares` (handles or squares) off the floor, as
--- a player picking them up leaves none behind; they land in self.reads[label].items (when given),
--- each { type, uses (a drainable's), modData (its plain values) }.
function T.takeFloorItems(self, squares, label)
    local at = {}
    for i, square in ipairs(squares) do
        at[i] = T.at(square)
    end
    T.read(self, "PZHarness.takeFloorItems", { squares = at }, label)
end

--- Queues a wooden floor one level above `at`'s square laid by the authority, as a player roofs a
--- yard, until the test ends; whether the square below is still outdoors lands in
--- self.reads[label].outside (when given).
function T.floorAbove(self, at, label)
    T.read(self, "PZHarness.floorAbove", T.at(at), label)
end

--- Queues a tile of `sprite` on each of the eight squares around `at` on level `level`, laid by
--- the authority until the test ends, the squares made where that level has none.
function T.ringOfTiles(self, at, level, sprite)
    T.server(self, "PZHarness.ringOfTiles", T.at(at, { level = level, sprite = sprite }))
end

-- A free square next to the character, with no wall in between, for a bench of `entity`; nil, and
-- missing, without one.
local function benchSquare(self, entity)
    local square = PZHarness.Fixtures.freeAdjacentSquare(T.player():getSquare(), self.used)
    if square then
        self.used[square] = true
    end
    return T.need(self, square, "a free square next to the character for a " .. entity)
end

-- Sends the call of handler `name`, which places something, and queues a wait until `find()`
-- finds this client's copy, into handle[key] ("object" unless given); `onReply(reply)` gets the
-- answer first. Single player finds it at once.
local function placeOnServer(self, handle, name, args, find, what, key, onReply)
    key = key or "object"
    local poll = Runtime.call(self, name, args, nil, onReply, nil, {
        ready = function()
            handle[key] = find()
            return handle[key] ~= nil
        end,
        what = "this client's copy of " .. what,
        ms = RECEIVE_MS,
    })
    poll() -- Single player finds its copy synchronously.
    Runtime.wait(math.huge, nil, poll, "this client's copy of " .. what)
    return handle
end

--- A tile object of `sprite` on `square`, with `modData`, placed the way the authority does: on
--- the server in multiplayer, which sends it to the clients. Removed when the test ends as T.track
--- removes, by the dev mod's `remove` setting if it takes it, else the vanilla way. Returns a
--- handle { x, y, z, square } at once; handle.object is this client's copy, there at once in
--- single player and after a queued wait in multiplayer.
function T.placeTile(self, square, sprite, modData)
    local handle = T.where(square)
    local args = T.at(handle, { sprite = sprite, modData = modData })
    return placeOnServer(self, handle, "PZHarness.tile", args, function()
        return T.objectWithSprite(getSquare(handle.x, handle.y, handle.z), sprite)
    end, "a " .. sprite)
end

--- A workstation of the entity script `entity` (such as "Base.Kiln_Small"), drawn as `sprite`,
--- on a free square next to the character, who is using it as its crafting window makes them;
--- placed the way the authority does, as T.placeTile places a tile: returns a handle
--- { x, y, z, square } at once, or nil without a free square, and handle.object is this client's
--- copy of the bench once it has one.
function T.placeBench(self, entity, sprite)
    local square = benchSquare(self, entity)
    if not square then
        return nil
    end
    local handle = T.where(square)
    local args = T.at(handle, { entity = entity, sprite = sprite })
    return placeOnServer(self, handle, "PZHarness.bench", args, function()
        local bench = T.objectWithSprite(getSquare(handle.x, handle.y, handle.z), sprite)
        return bench and bench:getComponent(ComponentType.CraftBench) and bench
    end, "a " .. entity)
end

--- Puts the character in the middle of the free square next to `square` that vanilla's walkAdj
--- would walk it to (AdjacentFreeTileFinder.Find), or of its own square if there is none, facing
--- `square`, so the walk that a menu option or an action queues before its job has no way to go
--- and the turn its waitToStart waits for (faceThisObject, shouldBeTurning) is already done.
--- Walking and turning take real time, which neither the instant cheat nor the frame rate
--- shortens.
function T.standNextTo(square)
    local p = T.player()
    local adjacent = AdjacentFreeTileFinder.Find(luautils.getCorrectSquareForWall(p, square), p)
    local at = adjacent or p:getCurrentSquare()
    PZHarness.Fixtures.teleportToMiddle(p, at:getX(), at:getY(), at:getZ())
    local dx, dy = square:getX() - at:getX(), square:getY() - at:getY()
    if dx ~= 0 or dy ~= 0 then
        p:setTargetAndCurrentDirection(dx, dy)
    end
end

--- Queues T.standNextTo(square), then on a multiplayer client puts the server's copy of the
--- character on the same square. A client sends its position on a timer, up to a second apart, as
--- a move from floor to floor doesn't count as a new square for it (NetworkPlayerAI, under the
--- default AntiCheatNoClip), and the server then walks its copy toward the newest position it got,
--- a step each update: an instant timed action queued meanwhile reaches its complete() on the
--- server at the wrong place. So the client sends its new position at once (setIgnoreMovement asks
--- for an update), and once the character's square has caught up, the request that moves the
--- server's copy goes after that update, which the server then already walks toward.
function T.goNextTo(self, square)
    local at = {}
    T.step(function()
        T.standNextTo(square)
        local p = T.player()
        at.x, at.y, at.z = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
        if isClient() then
            local ignoring = p:getIgnoreMovement()
            p:setIgnoreMovement(true)
            p:setIgnoreMovement(ignoring)
        end
    end)
    if not isClient() then
        return
    end
    -- The character's square catches up with a teleport only on its next update.
    Runtime.waitUntil(function()
        local here = T.player():getCurrentSquare()
        return here ~= nil and here:getX() == at.x and here:getY() == at.y
    end, RECEIVE_MS)
    T.server(self, "PZHarness.moveTo", function() return at end)
end

--- Stands the character next to `square` so vanilla's walkAdj has nowhere to go, then makes that
--- walk, as a menu does before an action: a multiplayer server refuses a job from afar. Missing
--- "a walk to `what`" if it can't.
function T.walkTo(self, square, what)
    T.standNextTo(square)
    return T.need(self, luautils.walkAdj(T.player(), square, true), "a walk to " .. what)
end

--- Queues a job at `square`: the character goes next to it (T.goNextTo) unless it already stands
--- where the last T.doJob put it, then `makeAction()`'s timed action is queued. Decided when the
--- queue reaches it, so a teleport between jobs counts.
function T.doJob(self, square, makeAction)
    T.step(function()
        if self.jobSquare ~= square or self.jobStand ~= T.player():getCurrentSquare() then
            T.goNextTo(self, square)
            T.step(function() self.jobSquare, self.jobStand = square, T.player():getCurrentSquare() end)
        end
        T.step(function() ISTimedActionQueue.add(makeAction()) end)
    end)
end

-- Queues the moveables action `mode` ("place" or "pickup") of `sprite` on `square` the way the
-- moveables cursor does (ISMoveableCursor.create): the character walks next to the square and the
-- action does the job, in multiplayer in its complete() on the server. The caller has queued
-- T.goNextTo first, as vanilla's walkAdj misjudges the reach from a square's edge, and judged from
-- a square a teleport hasn't yet updated it queues a walk to where the character already stands,
-- whose path can fail and clear the queue. Returns false if the character can't get there.
local function moveablesAction(square, mode, sprite, item, object)
    local p = T.player()
    local props = object and ISMoveableSpriteProps.fromObject(object) or ISMoveableSpriteProps.new(sprite)
    if not props:walkToAndEquip(p, square, mode, sprite) then
        return false
    end
    local direction = props:getFaceDirectionFromSpriteName(sprite)
    ISTimedActionQueue.add(ISMoveablesAction:new(p, square, mode, sprite, object, direction, item, nil))
    return true
end

--- Queues placing a new `itemType`, with `modData` on the item, on `square` the way a player does:
--- the character is given it (T.give), walks next to the square and places it with the moveables
--- action, which a multiplayer server carries out. What it placed goes when the test ends, as
--- T.placeTile's does. Returns a handle { x, y, z, square } at once; handle.object is this client's
--- copy of the placed object, drawn as `sprite`, once it has arrived.
function T.placeAsPlayer(self, square, itemType, sprite, modData)
    self.placedAsPlayer = (self.placedAsPlayer or 0) + 1
    local key = "PZHarness.placeAsPlayer" .. self.placedAsPlayer
    local handle = T.where(square)
    T.give(self, key, { { type = itemType, modData = modData } })
    T.goNextTo(self, square)
    Runtime.wait(1, function()
        if not T.need(self, moveablesAction(square, "place", sprite, self.items[key][1], nil), "a way to place a " .. itemType) then
            return
        end
        Runtime.waitUntil(function() return T.objectWithSprite(square, sprite) ~= nil end, RECEIVE_MS)
        T.server(self, "PZHarness.trackPlaced", T.at(handle, { sprite = sprite }))
        Runtime.wait(1, function()
            handle.object = T.need(self, T.objectWithSprite(square, sprite), "this client's copy of a placed " .. itemType)
        end)
    end)
    return handle
end

--- Queues picking up the object drawn as `sprite` on `at` (a square, or a handle with a `square`)
--- the way a player does, with the moveables action, and a wait until this client no longer has
--- it.
function T.pickUpAsPlayer(self, at, sprite)
    local square = type(at) == "table" and at.square or at
    T.goNextTo(self, square)
    Runtime.wait(1, function()
        local object = T.objectWithSprite(square, sprite)
        if not T.need(self, object and moveablesAction(square, "pickup", sprite, nil, object), "a way to pick up the " .. sprite) then
            return
        end
        Runtime.waitUntil(function() return T.objectWithSprite(square, sprite) == nil end, RECEIVE_MS)
    end)
end

-- The squares T.placeVehicle tries, nearest first: `opts.square`, else open ground near
-- `opts.near` (the character by default), far enough that the vehicle doesn't land on it.
local function vehicleSquares(self, opts)
    return opts.square and { opts.square }
        or freeSquares(self, VEHICLE_TRIES, { near = opts.near, minDistance = 4, bare = true })
end

-- This client's copies of the vehicles T.placeVehicle found, to the handle each was found for.
-- The server reuses the most recently freed vehicle id (VehicleIDMap), often the one the previous
-- test just removed, and a client that hasn't processed that removal still finds the stale copy.
-- So a copy found for one handle is never taken for another. Kahlua has no weak tables, so
-- T.placeVehicle prunes removed copies.
local foundVehicles = {}
-- How long a multiplayer client waits after its copy of a new vehicle arrives, for the server's
-- second full update of it (see T.placeVehicle). A request still queued when the copy came goes
-- out within 100 ms (GameClient's requestsFrequency), and the server answers on its next vehicle
-- send, at most every 100 ms and only on its own updates, ten a second (VehicleManager.updateRate),
-- so up to about 300 ms in all. Nothing Lua can see says whether a second request was queued or
-- when its update came, so the wait can't end sooner.
local VEHICLE_SETTLE_MS = 300

--- A vehicle of `script` placed the way the authority does: on the server in multiplayer, which
--- sends it to the clients nearby; removed when the test ends. `opts`: `square` or `near` (see
--- vehicleSquares), `facing` ("N" unless given), `args` (plain values for the dev mod's
--- `spawnVehicle` setting, which makes the vehicle if it returns one). Returns a handle at once.
--- Once the server has answered, handle.id (shared by the server and its clients;
--- PZHarness.Fixtures.vehicleById finds it on either side), x, y, z and square say where it went,
--- and after a queued wait handle.vehicle is this client's copy.
function T.placeVehicle(self, script, opts)
    opts = opts or {}
    local removed = {}
    for vehicle in pairs(foundVehicles) do
        if vehicle:isRemovedFromWorld() then
            table.insert(removed, vehicle)
        end
    end
    for _, vehicle in ipairs(removed) do
        foundVehicles[vehicle] = nil
    end
    local squares = {}
    for _, square in ipairs(vehicleSquares(self, opts)) do
        table.insert(squares, T.at(square))
    end
    local handle = {}
    local args = { script = script, squares = squares, facing = opts.facing, args = opts.args }
    placeOnServer(self, handle, "PZHarness.vehicle", args, function()
        local vehicle = PZHarness.Fixtures.vehicleById(handle.id, handle)
        if not vehicle or vehicle:isRemovedFromWorld() or (foundVehicles[vehicle] or handle) ~= handle then
            return nil
        end
        foundVehicles[vehicle] = handle
        return vehicle
    end, "a " .. script, "vehicle", function(reply)
        handle.id, handle.x, handle.y, handle.z = reply.id, reply.x, reply.y, reply.z
        handle.square = getSquare(reply.x, reply.y, reply.z)
    end)
    -- A client that meets an unknown vehicle id asks for a full update, possibly twice. The server
    -- sends the second in place of pending part changes and clears them, while a client that has
    -- the vehicle takes only its position from it (VehicleManager.sendVehicles,
    -- VehicleFullUpdatePacket): a part change made before the second arrives is lost here.
    if isClient() then
        local sinceMs
        Runtime.wait(math.huge, nil, function()
            sinceMs = sinceMs or getTimestampMs()
            return getTimestampMs() - sinceMs >= VEHICLE_SETTLE_MS
        end, "the second full update of a " .. script)
    end
    return handle
end

