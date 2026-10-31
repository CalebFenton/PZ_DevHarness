# Performance in Project Zomboid mods

How to find and avoid the work a mod's Lua does on its own: event handlers, global object systems,
sprite and light changes. Figures are from Build 42.21 in single player on an Apple M3 Max; take
them as orders of magnitude.

## Find the handler that costs the frame before changing code

A hitch is one long frame, and reading code finds many plausible costs but not which one took it,
so time the frame first. Wrap every `Events.<name>.Add` from a file that loads before the mods to
be timed, and log each call over a threshold and each frame gap over a threshold with the handlers
that ran in it. Lua loads folder by folder (shared, then client, then server); within a folder,
vanilla's files first, then each mod's in load order, sorted by name ignoring case. So a shared
file of the first mod loaded, named to sort first, times every mod's handlers and vanilla's client
and server ones. `getTimestampMs` is the only clock: one quick call reads 0 or 1 ms, but a sum
over many calls is unbiased. A frame gap that no timed handler accounts for went to Java, or to
Lua outside events (UI `render`, map-object loaders, timed actions, recipe `OnTest`); look there
rather than shaving the handlers.

## Budget each event by its real-time cadence

`Events.EveryOneMinute` fires every few real seconds (3.75 s in a default game), so treat it as
near real time; `EveryTenMinutes` comes about every 40 s, `EveryHours` every few minutes, `OnTick`
every frame. A per-minute handler that takes a second is the "lags every few seconds" players
report. Keep per-minute and per-tick work in proportion to the mod's own tracked objects; a scan
of squares or of items belongs in a ten-minute pass or behind an event that says something
changed.

## Count Lua-to-Java calls, not the work Java does

In Kahlua, the call into Java costs more than most of what the Java method then does, so the
number of calls is the cost. Walking a generator's reach (about 8,800 squares) with one
`getGridSquare` and one getter each took 4.1 ms; walking 102 objects on one square with a Lua
check each took 28 µs. Prefer one Java call that does the loop (`square:getGenerator()`,
`getFirstTypeRecurse`, `getNextNonItemObjectIndex`) to a Lua loop of small calls. When a search
finds nothing, keep that answer until something that could change it happens, such as a generator
starting, not only for the current instant: otherwise every pass repeats the full search.

## Skip dropped items when looking for a tile

A square's `getObjects()` holds every item dropped on it, as an `IsoWorldInventoryObject`, and a
lived-in base has squares with hundreds. A lookup for a tile that walks them all pays a call per
item. Walk with `square:getNextNonItemObjectIndex(i)` instead: on a square with 100 dropped items,
2.5 µs a lookup against 28.5 µs. Vanilla's `SGlobalObjectSystem:getIsoObjectOnSquare` and
`CGlobalObjectSystem:getIsoObjectOnSquare` walk every object, calling `getObjects()` again for
each one, so a derived system overrides them. Illustrative:

```lua
local function findObjectOn(square, matches)
    if not square then return nil end
    local objects = square:getObjects()
    local i = square:getNextNonItemObjectIndex(0)
    while i ~= -1 do
        local object = objects:get(i)
        if matches(object) then return object end
        i = square:getNextNonItemObjectIndex(i + 1)
    end
    return nil
end
```

## Set a sprite only when it differs

`IsoObject:setSprite`, `setCustomColor` and `addAttachedAnimSprite*` mark the chunk level's cached
render dirty on every call, the same sprite included, and the level is drawn again with everything
on it; `setOverlaySprite` compares first. Compare the current sprite's name before setting it, and
compare the attached overlays as a list before removing and re-adding them. To animate a tile,
`setAnimating(true)` keeps it out of the cached chunk and `setSpriteModelName` only stores a name,
so each step costs nothing extra.

## Add a light only when the cell lost it

`IsoCell:addLamppost` starts a full lighting recalculation, so a "make sure the lamp is there"
check must not add one each pass. Keep the returned `IsoLightSource` and add it again only when
`getLightSourceAt` no longer returns it, which happens when its chunk unloaded.

## Prove a fix in the scene that showed the cost

A fix is done when the same timed run, in the same cluttered scene, shows the handler's time or the
frame gaps gone; a faster function that wasn't in the slow frame changes nothing a player sees.
Time a candidate in isolation as well, with the worst case it meets: a search that finds nothing
walks everything.
