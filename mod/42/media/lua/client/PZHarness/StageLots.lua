-- Development only, not published. Lots and places for capture modes (docs/adopting.md,
-- "Staging"). It adds to PZHarness.Stage (PZHarness/Stage.lua).

require "PZHarness/Fixtures"
local Stage = require "PZHarness/Stage"
local Capture = require "PZHarness/Capture"

-- The start of the names of the floors of soil and grass, which a world's generation blends.
Stage.NATURAL_FLOOR = "blends_natural"

-- Open ground ---------------------------------------------------------------------------------------

local function floorName(square)
    local floor = square:getFloor()
    return floor and PZHarness.Fixtures.spriteName(floor)
end

-- Whether `wall`, a square's wall on one edge or nil, leaves it open ground of `opts`: checked apart
-- from the other objects, since a wall may also count as ground cover.
local function isWallAllowed(wall, opts)
    return wall == nil or (not opts.bare and opts.allows ~= nil and opts.allows(wall))
end

-- Whether `object` may stand on open ground of `opts`, besides the square's floor `floor`. Other
-- objects can carry the floor flag too, such as boulders, which stand in a shot as anything else
-- does.
local function isAllowed(object, floor, opts)
    if object == floor then
        return true
    end
    if opts.bare then
        return false
    end
    return (opts.trees and object:getType() == IsoObjectType.tree) or Stage.isGroundCover(object)
        or (opts.allows ~= nil and opts.allows(object))
end

--- Whether `square` is open ground: loaded, outdoors and in no room, on solid floor that isn't
--- water, with no vehicle, and nothing on it but floor, ground cover (Stage.clearGroundCover takes
--- it) and what `opts` allows, and no wall unless `opts.allows` takes it. `opts`, all optional:
--- `bare`, nothing but floor, not even ground cover; `trees`, trees too; `allows(object)`, other
--- objects too; `floor`, the floor's sprite name starts with it (Stage.NATURAL_FLOOR for soil or
--- grass); `free`, nothing on it stops a character walking onto it (IsoGridSquare.isFree).
function Stage.isOpenGround(square, opts)
    opts = opts or {}
    if square == nil or not square:isOutside() or square:getRoom() ~= nil or not square:isSolidFloor()
        or square:getProperties():has(IsoFlagType.water) or square:getVehicleContainer() ~= nil
        or (opts.free and not square:isFree(false))
        or not isWallAllowed(square:getWall(true), opts) or not isWallAllowed(square:getWall(false), opts) then
        return false
    end
    if opts.floor then
        local name = floorName(square)
        if name == nil or not luautils.stringStarts(name, opts.floor) then
            return false
        end
    end
    local floor, objects = square:getFloor(), square:getObjects()
    for i = 0, objects:size() - 1 do
        if not isAllowed(objects:get(i), floor, opts) then
            return false
        end
    end
    return true
end

--- Whether `accepts(square)` holds for every square of the `w` by `h` rectangle whose north-west
--- corner is `corner`, on its level. `accepts` is passed nil for a square not loaded; a nil
--- `corner` is not open.
function Stage.isAreaOpen(corner, w, h, accepts)
    if not corner then
        return false
    end
    local cell, x, y, z = getCell(), corner:getX(), corner:getY(), corner:getZ()
    for dy = 0, h - 1 do
        for dx = 0, w - 1 do
            if not accepts(cell:getGridSquare(x + dx, y + dy, z)) then
                return false
            end
        end
    end
    return true
end

-- Lots ----------------------------------------------------------------------------------------------

-- Whether a lot `w` by `h` at x, y keeps `gap` squares from each of `others`.
local function isApart(x, y, w, h, others, gap)
    for _, other in ipairs(others) do
        if x < other.x + other.w + gap and other.x < x + w + gap and y < other.y + other.h + gap
            and other.y < y + h + gap then
            return false
        end
    end
    return true
end

--- The closest lot `w` by `h` squares whose every square is open ground (Stage.isOpenGround with
--- `opts`), as { x, y, z, w, h }, its north-west corner and size, and a place on that corner
--- (Stage.place), or nil. With `opts.others` (lots this returned), it keeps `opts.gap` squares from
--- each of them; with `opts.clearance`, the squares that far round it are open ground too, of any
--- floor, so that no building or fence stands at its edge.
function Stage.findLot(player, w, h, opts)
    opts = opts or {}
    local others, gap, c = opts.others or {}, opts.gap or 0, opts.clearance or 0
    local around = { bare = opts.bare, trees = opts.trees, allows = opts.allows, free = opts.free }
    local function open(square)
        return Stage.isOpenGround(square, opts)
    end
    local function openAround(square)
        return Stage.isOpenGround(square, around)
    end
    local cell = getCell()
    local corner = Stage.closestSquare(player, function(square)
        local x, y, z = square:getX(), square:getY(), square:getZ()
        return isApart(x, y, w, h, others, gap) and Stage.isAreaOpen(square, w, h, open)
            and (c == 0 or Stage.isAreaOpen(cell:getGridSquare(x - c, y - c, z), w + 2 * c, h + 2 * c, openAround))
    end)
    if not corner then
        return nil
    end
    local lot = Stage.place(corner)
    lot.x, lot.y, lot.z, lot.w, lot.h = corner:getX(), corner:getY(), corner:getZ(), w, h
    return lot
end

--- The square `dx`, `dy` squares east and south of `lot`'s corner, `up` floors above it, or nil
--- where none is loaded.
function Stage.lotSquare(lot, dx, dy, up)
    return getCell():getGridSquare(lot.x + dx, lot.y + dy, lot.z + (up or 0))
end

--- Every loaded square of `lot`, row by row from its corner, as a framing takes them.
function Stage.lotSquares(lot)
    local squares = {}
    for dx = 0, lot.w - 1 do
        for dy = 0, lot.h - 1 do
            local square = Stage.lotSquare(lot, dx, dy)
            if square then
                table.insert(squares, square)
            end
        end
    end
    return squares
end

--- Recalculates `lot`'s squares and those beside it, once what was set on them is in place, so
--- that they draw it: a tile's look depends on its neighbours'.
function Stage.recalcLot(lot)
    for dx = -1, lot.w do
        for dy = -1, lot.h do
            local square = Stage.lotSquare(lot, dx, dy)
            if square then
                square:RecalcAllWithNeighbours(true)
            end
        end
    end
end

-- Places ----------------------------------------------------------------------------------------------

-- A place is a square its positions are measured from, `origin`, and a frame, the directions a
-- position's two numbers, { along, out }, run in. An area of a place is the squares from along[1]
-- to along[2] and out[1] to out[2]; with `sum` and `half`, only those whose along + out is within
-- `half` of `sum`, a band across the screen.

--- The frame of positions in (east, south) squares, which a lot's are.
Stage.GRID = { along = { 1, 0 }, out = { 0, 1 } }

--- A place on `origin` in `frame`, Stage.GRID by default.
function Stage.place(origin, frame)
    return { origin = origin, frame = frame or Stage.GRID }
end

--- The square at `position` ({ along, out }) of `place`, or nil where none is loaded.
function Stage.at(place, position)
    local origin, frame = place.origin, place.frame
    local along, out = position[1], position[2]
    return getCell():getGridSquare(origin:getX() + along * frame.along[1] + out * frame.out[1],
        origin:getY() + along * frame.along[2] + out * frame.out[2], origin:getZ())
end

--- The squares of `place` at the positions of each list of positions given, in order.
function Stage.squaresAt(place, ...)
    local squares = {}
    for i = 1, select("#", ...) do
        for _, position in ipairs((select(i, ...))) do
            table.insert(squares, Stage.at(place, position))
        end
    end
    return squares
end

--- The squares of `place` at `positions` that are loaded and, if given, pass `accepts(square)`.
function Stage.loadedSquares(place, positions, accepts)
    local squares = {}
    for _, position in ipairs(positions) do
        local square = Stage.at(place, position)
        if square and (not accepts or accepts(square)) then
            table.insert(squares, square)
        end
    end
    return squares
end

--- Whether fn(square) holds for every square of `area` of `place`, stopping at the first that
--- fails. From out `outFrom` rather than the area's own first if given.
function Stage.everyAreaSquare(place, area, fn, outFrom)
    for along = area.along[1], area.along[2] do
        for out = outFrom or area.out[1], area.out[2] do
            local inBand = not area.sum or math.abs(along + out - area.sum) <= area.half
            if inBand and not fn(Stage.at(place, { along, out })) then
                return false
            end
        end
    end
    return true
end

-- Whether `square` stands at least `gap` from each of `places`' origins along x or y.
local function isApartFrom(square, places, gap)
    for _, other in ipairs(places) do
        local origin = other.origin
        if math.abs(square:getX() - origin:getX()) < gap and math.abs(square:getY() - origin:getY()) < gap then
            return false
        end
    end
    return true
end

--- The place closest to the character in the first of `frames` that has one for which
--- fits(place) holds and whose origin stands at least `gap` from each of `others`' origins along
--- x or y, or nil.
function Stage.closestPlace(player, frames, fits, others, gap)
    for _, frame in ipairs(frames) do
        local best = Stage.closestSquare(player, function(origin)
            return isApartFrom(origin, others, gap) and fits(Stage.place(origin, frame))
        end)
        if best then
            return Stage.place(best, frame)
        end
    end
    return nil
end

--- Finds the places of `specs` that `needs` names, in order, each apart from those found before
--- it, and logs them in one line under `mark`. Returns them by name and their origins in order, or
--- nil and the `missing` of the first it can't find. A spec has a `name`, a `label` for the log,
--- what is `missing` without it, and either `frames` and `fits(place, player)` (Stage.closestPlace),
--- or `find(player, found)`; `detail(place)` adds to its entry in the log.
function Stage.findPlaces(player, specs, needs, mark, gap)
    local places, found, origins, logged = {}, {}, {}, {}
    for _, spec in ipairs(specs) do
        if needs[spec.name] then
            local place
            if spec.find then
                place = spec.find(player, found)
            else
                place = Stage.closestPlace(player, spec.frames, function(candidate)
                    return spec.fits(candidate, player)
                end, found, gap)
            end
            if not place then
                return nil, spec.missing
            end
            places[spec.name] = place
            table.insert(found, place)
            local origin, facing = place.origin, place.frame.facing
            table.insert(origins, origin)
            table.insert(logged, string.format("%s %d,%d", spec.label, origin:getX(), origin:getY())
                .. (facing and " facing " .. facing or "") .. (spec.detail and spec.detail(place) or ""))
        end
    end
    if #logged > 0 then
        print(mark .. " " .. table.concat(logged, "; "))
    end
    return places, origins
end

-- Tiles and clearing ----------------------------------------------------------------------------------

--- A tile of `spriteName` with `modData` placed on `square` at once, on this side, as
--- PZHarness.Fixtures.newTile places one, its neighbours recalculated so it draws at once. Returns
--- it. Unlike a test's T.placeTile, nothing removes it.
function Stage.placeTile(square, spriteName, modData)
    local object = PZHarness.Fixtures.newTile(square, spriteName, modData)
    square:RecalcAllWithNeighbours(true)
    return object
end

--- Takes every object off `square` but its floor and those `keeps(object)` accepts, from the top
--- down.
function Stage.clearToFloor(square, keeps)
    local floor, objects = square:getFloor(), square:getObjects()
    for i = objects:size() - 1, 0, -1 do
        local object = objects:get(i)
        if object ~= floor and not (keeps and keeps(object)) then
            square:RemoveTileObject(object)
        end
    end
end

--- Clears `lot`'s squares, and `margin` more round it, of trees and ground cover, so that nothing
--- stands in the way of what is set on it.
function Stage.clearLot(lot, margin)
    margin = margin or 0
    for dx = -margin, lot.w + margin - 1 do
        for dy = -margin, lot.h + margin - 1 do
            local square = Stage.lotSquare(lot, dx, dy)
            local tree = square and square:getTree()
            if tree then
                square:RemoveTileObject(tree)
            end
            Stage.clearGroundCover(square)
        end
    end
end

--- Stage.clearLot for shots, which also takes the trees further round (Stage.removeTrees): they
--- draw black where the character can't see them.
function Stage.clearLotForShots(lot, margin)
    Stage.removeTrees(lot.x, lot.y, lot.z)
    Stage.clearLot(lot, margin)
end

--- Takes `lot` down to its floors: every item lying on it and every object but the floor go, and
--- the lot is recalculated, so that the next stage starts on an empty lot.
function Stage.emptyLot(lot)
    for dx = 0, lot.w - 1 do
        for dy = 0, lot.h - 1 do
            local square = Stage.lotSquare(lot, dx, dy)
            if square then
                square:removeAllWorldObjects()
                Stage.clearToFloor(square)
            end
        end
    end
    Stage.recalcLot(lot)
end

-- Shots on a lot or a place --------------------------------------------------------------------------

local function noRegions()
    return {}
end

--- Adds the steps that turn the clock to `shot.hour` if given, walk the character to the square
--- `shot.x`, `shot.y` of `lot`, let it look around, set the zoom `shot.zoomSteps` out from the
--- closest and shoot the screen as `shot.name` with no regions, for a mode that writes no JSON.
function Stage.addSpotShot(run, player, lot, shot)
    if shot.hour then
        Stage.addHour(run, shot.hour)
    end
    Stage.addGoTo(run, player, { Stage.lotSquare(lot, shot.x, shot.y) }, shot.zoomSteps)
    run:addOpaque(shot.name, noRegions)
end

-- The item model shots, each item alone on a floor laid around the studio square, at the closest
-- zoom the game draws, which the zoom options leave out (Stage.pushClosestZoom). Positions are
-- (east, south) squares from the studio square. The character stands off to the side, to the item's
-- left on the screen.
Stage.STUDIO = {
    -- The open ground the floor needs, and how far around the studio square the floor goes where
    -- the ground is clear, and the plants go anyway, since the bigger items' shots reach past it.
    open = { along = { -3, 3 }, out = { -3, 3 } },
    floor = { along = { -5, 5 }, out = { -5, 5 } },
    player = { -1, 1 },
    -- Where lib/capture.py looks for the item, in UI units around the studio square's floor
    -- centre: room for the tallest models, and clear of the character.
    window = { half = 360, up = 700, down = 300 },
    -- Turned so that the long side of most models faces the camera.
    rotation = 315,
}

--- The findPlaces spec of the studio, open ground the character isn't standing on.
Stage.STUDIO_PLACE = {
    name = "studio",
    label = "items",
    missing = "open ground for the item shots' floor",
    frames = { Stage.GRID },
    fits = function(place, player)
        return Stage.everyAreaSquare(place, Stage.STUDIO.open, function(square)
            return Stage.isOpenGround(square) and square ~= player:getCurrentSquare()
        end)
    end,
}

-- Where lib/capture.py looks for the item in a studio shot: STUDIO.window around the studio
-- square's floor centre, kept on the screen.
local function studioWindow(studio, name)
    local x, y = Stage.onScreen(studio.origin)
    local window = Stage.STUDIO.window
    return Stage.screenRegion(name, x - window.half, y - window.up, x + window.half, y + window.down)
end

--- Adds the steps that shoot each of `items` (Capture Catalog:items entries) alone on a floor of
--- `floorSprite` laid on the open ground of the place `studio` (Stage.STUDIO_PLACE): the bare floor
--- as <prefix>models_floor, then each item as <prefix>model_<Module>_<Type>, added to `models` with
--- the window lib/capture.py finds it in by difference from the floor.
function Stage.addFloorModels(run, studio, items, models, floorSprite)
    local group = run.current
    local floorSquare = studio.origin
    run:add(function()
        print(run.mark .. " item floor " .. floorSprite)
        Stage.everyAreaSquare(studio, Stage.STUDIO.floor, function(square)
            Stage.clearGroundCover(square)
            if Stage.isOpenGround(square) then
                square:addFloor(floorSprite)
            end
            return true
        end)
        Stage.pushClosestZoom()
        -- Every item at once, so that their models load while the character looks around: Lua
        -- can't tell when a model has loaded, and a loaded one draws on the next frame.
        for _, item in ipairs(items) do
            floorSquare:AddWorldInventoryItem(instanceItem(item.fullType), 0.5, 0.5, 0)
        end
    end)
    Stage.addGoTo(run, getPlayer(), { Stage.at(studio, Stage.STUDIO.player) }, 0)
    local floor = run.prefix .. "models_floor"
    run:add(function()
        floorSquare:removeAllWorldObjects()
        return Capture.DRAW_FRAMES
    end)
    run:add(function()
        run:screenshot(floor)
    end)
    for _, item in ipairs(items) do
        local name = "model_" .. string.gsub(item.fullType, "%.", "_")
        run:add(function()
            local placed = instanceItem(item.fullType)
            placed:setWorldZRotation(Stage.STUDIO.rotation)
            floorSquare:AddWorldInventoryItem(placed, 0.5, 0.5, 0)
            return Capture.DRAW_FRAMES
        end)
        run:add(function()
            local file = run.prefix .. name
            run:screenshot(file)
            table.insert(models, { name = name, group = group, file = file, floor = floor,
                window = studioWindow(studio, name) })
            floorSquare:removeAllWorldObjects()
        end)
    end
    run:add(Stage.popClosestZoom)
end

return Stage
