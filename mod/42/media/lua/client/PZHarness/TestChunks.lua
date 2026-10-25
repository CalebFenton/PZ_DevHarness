require "PZHarness/TestLib"
require "PZHarness/Fixtures"

-- The chunk reload trip: the character goes far enough away that this client saves a chunk and
-- lets it go, then comes back and loads it again, for tests of what a mod's objects do while their
-- chunk is away and what they come back as.
local T = PZHarness.Test

-- How far east of the chunk the character goes, in squares: well past a client's chunk map.
local AWAY = 600
-- Squares along a chunk's side, to tell which chunk a LoadChunk event loaded.
local CHUNK_SQUARES = 8
-- How long the character stays away once the chunk has unloaded, in real milliseconds. Back at
-- once, a chunk has been seen to load with a vehicle a test had removed before the trip, as an
-- earlier save of it held it; the game hot-saves loaded chunks every second
-- (IsoChunkMap.hotSaveFrequency).
local AWAY_MS = 2000

--- The longest a chunk may take to unload behind the character or load in front of it, in real
--- milliseconds: loading takes real time, whatever the frame rate.
T.CHUNK_MS = 60000
--- A `spec.timeoutSeconds` for a test with a chunk reload trip, which outlasts the runner's
--- default limit.
T.CHUNK_RELOAD_SECONDS = 150
--- The `spec.spOnly` reason of a test whose chunk must unload on the authority too.
T.CHUNK_RELOAD_SP_ONLY = "a multiplayer server keeps chunks loaded after the character leaves"

--- Lets `self` move the character until the test ends: returns teleport(x, y, z), which asks for
--- the move, made on the next tick, as a teleport from inside a timed action doesn't stick.
function T.teleporter(self)
    local p, target = T.player(), nil
    T.onTick(self, function()
        if target then
            p:teleportTo(target[1], target[2], target[3])
            target = nil
        end
    end)
    return function(x, y, z) target = { x, y, z } end
end

--- Queues a trip that unloads the chunk of `at` ({ x, y, z }) and loads it again: the character
--- goes far east of it, stays away a moment once the chunk has gone, and comes back to the square
--- they stood on when the trip set off. `whileAway()`, if given, queues what happens while the
--- chunk is gone. In single player the server is the same game and its chunk goes too; a
--- multiplayer server keeps chunks loaded long after the character leaves, so there the trip
--- reloads only this client's copy, sent again by the server (a test that needs the authority's
--- chunk gone is `spOnly = T.CHUNK_RELOAD_SP_ONLY`). A chunk that doesn't unload or load again
--- within T.CHUNK_MS, or comes back without LoadChunk (from a cache, with its state), fails the
--- test as missing it. A test that ends before the character is back puts them home.
function T.reloadChunk(self, at, whileAway)
    local p = T.player()
    local teleport = T.teleporter(self)
    local loads, home = 0, nil
    local function onLoadChunk(chunk)
        local origin = chunk:getGridSquare(0, 0, 0)
        local dx, dy = origin and at.x - origin:getX(), origin and at.y - origin:getY()
        if origin and dx >= 0 and dx < CHUNK_SQUARES and dy >= 0 and dy < CHUNK_SQUARES then
            loads = loads + 1
        end
    end
    Events.LoadChunk.Add(onLoadChunk)
    T.defer(self, function() Events.LoadChunk.Remove(onLoadChunk) end)
    T.defer(self, function()
        if home then
            PZHarness.Fixtures.teleportToMiddle(p, home.x, home.y, home.z)
        end
    end)
    T.step(function()
        local square = p:getCurrentSquare()
        home = { x = square:getX(), y = square:getY(), z = square:getZ() }
        teleport(at.x + AWAY + 0.5, at.y + 0.5, 0)
    end)
    T.waitFor(self, function() return getSquare(at.x, at.y, at.z) == nil end, "the trip's chunk unloaded on this client",
        T.CHUNK_MS)
    T.waitUntil(function() return false end, AWAY_MS, "a stay away from the trip's chunk")
    if whileAway then
        whileAway()
    end
    T.step(function() teleport(home.x + 0.5, home.y + 0.5, home.z) end)
    T.waitFor(self, function() return getSquare(at.x, at.y, at.z) ~= nil end,
        "the trip's chunk loaded again on this client", T.CHUNK_MS)
    T.step(function()
        home = nil
        T.need(self, loads > 0, "the trip's chunk loaded again through LoadChunk, not from a cache")
    end)
end

return T
