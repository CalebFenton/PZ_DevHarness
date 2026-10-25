-- Development only, not published. Lots for capture modes (docs/adopting.md, "Staging"): telling
-- open ground, finding a lot of it near the character, its squares, placing tiles on it so they
-- draw at once, and clearing it. It adds to PZHarness.Stage (PZHarness/Stage.lua).

require "PZHarness/Fixtures"
local Stage = require "PZHarness/Stage"

-- The start of the names of the floors of soil and grass, which a world's generation blends.
Stage.NATURAL_FLOOR = "blends_natural"

-- Open ground ---------------------------------------------------------------------------------------

local function floorName(square)
    local floor = square:getFloor()
    return floor and floor:getSprite() and floor:getSprite():getName()
end

-- Whether `wall`, a square's wall on one edge or nil, leaves it open ground of `opts`: checked apart
-- from the other objects, since a wall may also count as ground cover.
local function isWallAllowed(wall, opts)
    return wall == nil or (not opts.bare and opts.allows ~= nil and opts.allows(wall))
end

-- Whether `object` may stand on open ground of `opts`.
local function isAllowed(object, opts)
    if object:isFloor() then
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
        if name == nil or not PZHarness.startsWith(name, opts.floor) then
            return false
        end
    end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        if not isAllowed(objects:get(i), opts) then
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
--- `opts`), as { x, y, z, w, h }, its north-west corner and size, or nil. With `opts.others`
--- (lots this returned), it keeps `opts.gap` squares from each of them; with `opts.clearance`, the
--- squares that far round it are open ground too, of any floor, so that no building or fence
--- stands at its edge.
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
    return corner and { x = corner:getX(), y = corner:getY(), z = corner:getZ(), w = w, h = h } or nil
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

return Stage
