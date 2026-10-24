-- Development only, not published. Staging for capture modes (docs/adopting.md, "Staging"):
-- finding a place near the character and clearing it, walking the character to a shot and
-- letting the lighting settle, framing what a shot shows, the world every shot is taken in, the
-- window and menu shots, and the driver that runs a mode's groups. PZHarness/Capture.lua runs the
-- steps.

require "PZHarness/Fixtures"
require "ISUI/ISWorldObjectContextMenu"
local Capture = require "PZHarness/Capture"

PZHarness = PZHarness or {}
local Stage = {}
PZHarness.Stage = Stage

-- How far around the character a place is looked for, in squares.
Stage.SEARCH_RADIUS = 40
-- How far from a place the trees go: near a building, a tree out of the character's sight draws
-- as a black silhouette full of holes (IsoTree.render).
Stage.TREE_RADIUS = 30
-- The character faces the camera last.
local LOOK_AROUND = { IsoDirections.N, IsoDirections.E, IsoDirections.S, IsoDirections.W, IsoDirections.SE }
-- Lighting passes a facing is held for: the main thread hands the facing to the lighting thread on
-- its next update, the thread's next pass sees with it, and the pass after that one is back.
local LOOK_PASSES = 3
-- The lighting thread shows a change of facing within a few passes, so lighting this long
-- unchanged has settled.
local SETTLE_MS = 300
-- How far around the character the lighting has to settle, in squares.
local SETTLE_RADIUS = 15
-- Steps to scroll in to reach the closest zoom, with Stage.pushClosestZoom's level too.
local STEPS_TO_CLOSEST = 9
-- The closest zoom the game draws (MultiTextureFBO2.zoomLevelsDefault), past the options' default.
local CLOSEST_ZOOM = 25
-- How far around each origin Stage.addWorldSettings switches radios and televisions off.
local QUIET_RADIUS = 25
-- The wind speed at a wind intensity of 1 (ClimateManager.getWindspeedKph).
local FULL_WIND_KPH = 120
-- The tileset of the litter the world's generation strews on open ground: twigs, small stumps and
-- fallen branches (tiledefinitions_erosion, WorldGen's generic_plant), only some of which vanilla
-- flags as removable.
local LITTER = "d_generic_1_"

-- Finding and clearing ------------------------------------------------------------------------------

--- Calls fn(square) for every loaded square within `radius` of x, y on level z.
function Stage.eachSquareAround(x, y, z, radius, fn)
    local cell = getCell()
    for dx = -radius, radius do
        for dy = -radius, radius do
            local square = cell:getGridSquare(x + dx, y + dy, z)
            if square then
                fn(square)
            end
        end
    end
end

--- The loaded square closest to the character, within SEARCH_RADIUS on its level, for which
--- `accepts(square)` holds, or nil. Of squares as close, the one furthest west, then north.
function Stage.closestSquare(player, accepts)
    local here = player:getCurrentSquare()
    local x, y, z = here:getX(), here:getY(), here:getZ()
    local best, bestDistance, bestDx, bestDy
    -- Ring by ring outwards, until no square of the next ring can be as close as the best.
    for radius = 0, Stage.SEARCH_RADIUS do
        if bestDistance and radius * radius > bestDistance then
            break
        end
        for sx, sy in PZHarness.Fixtures.ring(x, y, radius) do
            local dx, dy = sx - x, sy - y
            local distance = dx * dx + dy * dy
            if not bestDistance or distance < bestDistance
                or (distance == bestDistance and (dx < bestDx or (dx == bestDx and dy < bestDy))) then
                local square = getCell():getGridSquare(sx, sy, z)
                if square and accepts(square) then
                    best, bestDistance, bestDx, bestDy = square, distance, dx, dy
                end
            end
        end
    end
    return best
end

--- Removes every tree within TREE_RADIUS of x, y on level z.
function Stage.removeTrees(x, y, z)
    Stage.eachSquareAround(x, y, z, Stage.TREE_RADIUS, function(square)
        local tree = square:getTree()
        if tree then
            square:RemoveTileObject(tree)
        end
    end)
end

--- Grass, weeds and bushes a character could pull up (as vanilla's remove-grass and building code
--- tell them from other objects), and litter.
function Stage.isGroundCover(object)
    local props = object:getProperties()
    local sprite = object:getSprite() and object:getSprite():getName()
    return (props ~= nil and (props:has(IsoFlagType.canBeRemoved)
        or (props:has(IsoFlagType.vegitation) and object:getType() ~= IsoObjectType.tree)))
        or (sprite ~= nil and PZHarness.startsWith(sprite, LITTER))
end

--- Clears the ground cover off `square`, so what is set on it shows. Takes a nil square.
function Stage.clearGroundCover(square)
    local objects = square and square:getObjects()
    for i = (objects and objects:size() or 0) - 1, 0, -1 do
        if Stage.isGroundCover(objects:get(i)) then
            square:RemoveTileObject(objects:get(i))
        end
    end
end

--- Removes every vehicle standing on a square from x1, y1 to x2, y2 on level z. Found through the
--- squares, since the cell keeps its vehicles in a Java Set (IsoCell.getVehicles), which Lua can't
--- walk.
function Stage.removeVehicles(x1, y1, x2, y2, z)
    local cell, found = getCell(), {}
    for x = x1, x2 do
        for y = y1, y2 do
            local square = cell:getGridSquare(x, y, z)
            local vehicle = square and square:getVehicleContainer()
            if vehicle then
                found[vehicle] = true
            end
        end
    end
    for vehicle in pairs(found) do
        vehicle:permanentlyRemove()
    end
end

--- Switches off the radios and televisions within QUIET_RADIUS of each of `origins` (squares),
--- which play with their captions floating over the shots. Returns how many.
function Stage.silenceRadios(origins)
    local silenced = 0
    for _, origin in ipairs(origins) do
        Stage.eachSquareAround(origin:getX(), origin:getY(), origin:getZ(), QUIET_RADIUS, function(square)
            local objects = square:getObjects()
            for i = 0, objects:size() - 1 do
                local object = objects:get(i)
                if instanceof(object, "IsoWaveSignal") and object:getDeviceData():getIsTurnedOn() then
                    object:getDeviceData():setIsTurnedOn(false)
                    silenced = silenced + 1
                end
            end
        end)
    end
    return silenced
end

-- Seeing and zooming --------------------------------------------------------------------------------

-- How many squares around the character it has seen, and the sum of their light levels: together
-- they change when a square is newly seen or its light changes.
local function lightingState(player)
    local here = player:getCurrentSquare()
    if not here then
        return nil, nil
    end
    local playerNum = player:getPlayerNum()
    local seen, light = 0, 0
    Stage.eachSquareAround(here:getX(), here:getY(), here:getZ(), SETTLE_RADIUS, function(square)
        seen = seen + (square:isSeen(playerNum) and 1 or 0)
        light = light + math.floor(square:getLightLevel(playerNum) * 100)
    end)
    return seen, light
end

--- A runSteps wait until the lighting around the character has settled: no square newly seen and
--- no light level changed for SETTLE_MS. With `change`, the lighting must change first, since a
--- change of the clock or a new light source takes most of a second to show.
function Stage.lightingSettled(player, change)
    -- The lighting changes only once per pass of its thread, and an uncapped run draws hundreds of
    -- frames a second, so the area is scanned once per pass rather than every frame.
    local interval = 1000 / getPerformance():getLightingFPS()
    local lastSeen, lastLight, since, sampled
    local changed = not change
    return function()
        local now = getTimestampMs()
        if sampled and now - sampled < interval then
            return false
        end
        sampled = now
        local seen, light = lightingState(player)
        if seen ~= lastSeen or light ~= lastLight or not since then
            changed = changed or since ~= nil
            lastSeen, lastLight, since = seen, light, now
            return false
        end
        return changed and now - since >= SETTLE_MS
    end
end

--- Adds to `steps` (a run's, or a runSteps list) the steps that put the character on `square` and
--- have it look around, since squares it never saw are drawn dark. Its sight sweeps round with
--- each turn, so only the last waits for the lighting to settle.
function Stage.addLookAround(steps, player, square)
    table.insert(steps, function()
        -- To the middle: teleportTo alone leaves it on the north-west corner, inside the footprint
        -- of whatever stands diagonally behind it.
        PZHarness.Fixtures.teleportToMiddle(player, square:getX(), square:getY(), square:getZ())
        return function()
            return player:getCurrentSquare() == square
        end
    end)
    for _, direction in ipairs(LOOK_AROUND) do
        local target = direction:ToVector()
        local length = math.sqrt(target:getX() ^ 2 + target:getY() ^ 2)
        local targetX, targetY = target:getX() / length, target:getY() / length
        -- Turned at once, body and animation, rather than over the half second a turn takes; its
        -- sight follows on the lighting thread, which runs at its own rate.
        table.insert(steps, function()
            player:setTargetAndCurrentDirection(targetX, targetY)
            local untilMs = getTimestampMs() + LOOK_PASSES * 1000 / getPerformance():getLightingFPS()
            return function()
                return getTimestampMs() >= untilMs
            end
        end)
    end
    table.insert(steps, function()
        return Stage.lightingSettled(player)
    end)
end

--- Sets the zoom `stepsOut` steps out from the closest, and returns a runSteps wait until it
--- settles.
function Stage.zoomOut(stepsOut)
    for _ = 1, STEPS_TO_CLOSEST do
        getCore():doZoomScroll(0, -1)
    end
    for _ = 1, stepsOut do
        getCore():doZoomScroll(0, 1)
    end
    return Capture.zoomSettled()
end

local savedZoomLevels

--- Adds the closest zoom the game draws to the zoom levels, which the options leave out, without
--- saving them; Stage.popClosestZoom puts them back.
function Stage.pushClosestZoom()
    local core = getCore()
    savedZoomLevels = { core:getOptionZoomLevels1x(), core:getOptionZoomLevels2x() }
    core:setOptionZoomLevels1x(savedZoomLevels[1] .. ";" .. CLOSEST_ZOOM)
    core:setOptionZoomLevels2x(savedZoomLevels[2] .. ";" .. CLOSEST_ZOOM)
    core:zoomLevelsChanged()
end

function Stage.popClosestZoom()
    local core = getCore()
    core:setOptionZoomLevels1x(savedZoomLevels[1])
    core:setOptionZoomLevels2x(savedZoomLevels[2])
    core:zoomLevelsChanged()
    savedZoomLevels = nil
end

-- Framing -----------------------------------------------------------------------------------------

-- The width of the README's images, in UI units, which the world crops default to.
Stage.WORLD_W = 1260
-- How far past what it frames a crop reaches, in UI units.
Stage.CROP_MARGIN = 40
-- How far above its floor's centre a square's tile reaches at zoom 1, in UI units: a tile is 128
-- by 256, its floor's diamond 128 by 64.
Stage.TILE_TOP = 224

--- Where a square's floor centre is on the screen, in UI units.
function Stage.onScreen(square)
    local x, y, z = square:getX() + 0.5, square:getY() + 0.5, square:getZ()
    return isoToScreenX(0, x, y, z), isoToScreenY(0, x, y, z)
end

--- The screen rectangle `squares` and what stands on them take up, in UI units: { left, right,
--- top, bottom }. `top(square)`, if given, says how far above its floor's centre a square's
--- tallest thing reaches at zoom 1, TILE_TOP by default, or nil for that.
function Stage.screenBox(squares, top)
    local zoom = getCore():getZoom(0)
    local halfW, halfH = 64 / zoom, 32 / zoom
    local box = { left = math.huge, right = -math.huge, top = math.huge, bottom = -math.huge }
    for _, square in ipairs(squares) do
        local x, y = Stage.onScreen(square)
        box.left = math.min(box.left, x - halfW)
        box.right = math.max(box.right, x + halfW)
        box.top = math.min(box.top, y - ((top and top(square)) or Stage.TILE_TOP) / zoom)
        box.bottom = math.max(box.bottom, y + halfH)
    end
    return box
end

--- The region from left, top to right, bottom, cut off at the screen's edges.
function Stage.screenRegion(name, left, top, right, bottom)
    left, top = math.max(0, left), math.max(0, top)
    right = math.min(getCore():getScreenWidth(), right)
    bottom = math.min(getCore():getScreenHeight(), bottom)
    return Capture.region(name, left, top, right - left, bottom - top)
end

-- A crop `width` wide from `left` (moved to stay on the screen), as tall as `box` and the margin.
local function worldRegion(name, left, box, width)
    local screenW, screenH = getCore():getScreenWidth(), getCore():getScreenHeight()
    local top = math.max(0, box.top - Stage.CROP_MARGIN)
    local bottom = math.min(screenH, box.bottom + Stage.CROP_MARGIN)
    return Capture.region(name, math.max(0, math.min(screenW - width, left)), top, width, bottom - top)
end

-- What every framing takes: `opts.width` (WORLD_W by default) and `opts.top` for screenBox.
local function framed(squares, opts)
    opts = opts or {}
    return Stage.screenBox(squares, opts.top), opts.width or Stage.WORLD_W
end

--- A crop `opts.width` wide with `squares` in the middle.
function Stage.centred(name, squares, opts)
    local box, width = framed(squares, opts)
    return worldRegion(name, (box.left + box.right - width) / 2, box, width)
end

--- A crop `opts.width` wide with `squares` against its right edge, leaving room on the left, as
--- for a title.
function Stage.rightAligned(name, squares, opts)
    local box, width = framed(squares, opts)
    return worldRegion(name, box.right + Stage.CROP_MARGIN - width, box, width)
end

--- Just `squares` and the margin, for an inset.
function Stage.cropped(name, squares, opts)
    local box = framed(squares, opts)
    local margin = Stage.CROP_MARGIN
    return Stage.screenRegion(name, box.left - margin, box.top - margin, box.right + margin, box.bottom + margin)
end

--- The smallest square crop around `squares` and the margin, kept on the screen.
function Stage.squareRegion(name, squares, opts)
    local box = framed(squares, opts)
    local screenW, screenH = getCore():getScreenWidth(), getCore():getScreenHeight()
    local size = math.min(screenW, screenH,
        math.max(box.right - box.left, box.bottom - box.top) + 2 * Stage.CROP_MARGIN)
    local left = math.max(0, math.min(screenW - size, (box.left + box.right - size) / 2))
    local top = math.max(0, math.min(screenH - size, (box.top + box.bottom - size) / 2))
    return Capture.region(name, left, top, size, size)
end

-- The world ----------------------------------------------------------------------------------------

--- Adds the step that sets what every shot of a run shares: the hour `settings.hour` if given,
--- full colour, the wind intensity `settings.wind` if given, and no radio captions around
--- `settings.origins` (squares). The harness's clearWeather flag clears the rest of the weather.
function Stage.addWorldSettings(run, settings)
    run:add(function()
        if settings.hour then
            getGameTime():setTimeOfDay(settings.hour)
        end
        local climate = getClimateManager()
        -- A fresh world's climate greys the picture by its season, so two runs' shots would differ.
        local desaturation = climate:getClimateFloat(ClimateManager.FLOAT_DESATURATION)
        desaturation:setEnableAdmin(true)
        desaturation:setAdminValue(0)
        if settings.wind then
            local wind = climate:getClimateFloat(ClimateManager.FLOAT_WIND_INTENSITY)
            wind:setEnableAdmin(true)
            wind:setAdminValue(settings.wind)
        end
        print(run.mark .. " switched off " .. Stage.silenceRadios(settings.origins or {}) .. " radios and televisions")
        if not settings.wind then
            return 1
        end
        -- The climate takes the wind on its next update.
        return function()
            return climate:getWindspeedKph() >= settings.wind * FULL_WIND_KPH * 0.95
        end
    end)
end

--- Adds the step that sets the clock to `hour` and waits for the lighting to follow, which takes
--- most of a second.
function Stage.addHour(run, hour)
    run:add(function()
        getGameTime():setTimeOfDay(hour)
        return Stage.lightingSettled(getPlayer(), true)
    end)
end

-- Interface shots ----------------------------------------------------------------------------------

--- Adds the steps that open a window on a backdrop and shoot it matted as `name`: `opts.open()`
--- returns the window, which is moved to 100, 100; the shot waits until `opts.ready(window)`, if
--- given, holds, and the UI has drawn again. With `opts.near()` returning a square, the character
--- stands beside it meanwhile, as a window that closes out of its object's reach needs, and goes
--- back after. `opts.close(window)` closes it, `window:close()` by default.
function Stage.addWindowShot(run, name, opts)
    local window, back
    run:add(function()
        run:newBackdrop()
        local player = getPlayer()
        local near = opts.near and opts.near()
        if near then
            back = { math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ()) }
            local stand = AdjacentFreeTileFinder.Find(near, player) or near
            PZHarness.Fixtures.teleportToMiddle(player, stand:getX(), stand:getY(), stand:getZ())
        end
        window = opts.open()
        window:setX(100)
        window:setY(100)
        return function()
            return not opts.ready or opts.ready(window)
        end
    end)
    run:add(function()
        return Capture.drawn(Capture.DRAW_FRAMES)
    end)
    run:addMatted(name, function()
        return { Capture.elementRegion(name, window) }
    end)
    run:add(function()
        if opts.close then
            opts.close(window)
        else
            window:close()
        end
        if back then
            PZHarness.Fixtures.teleportToMiddle(getPlayer(), back[1], back[2], back[3])
            back = nil
        end
    end)
    run:removeBackdrop()
end

--- The submenu of `menu`'s option named `name`, opened as if the mouse were over the option, or
--- nil.
function Stage.openSubMenu(menu, name)
    for i, option in ipairs(menu and menu.options or {}) do
        if option.name == name and option.subOption then
            menu.mouseOver = i
            return menu:getSubMenu(option.subOption)
        end
    end
    return nil
end

--- Adds the steps that build a context menu on a backdrop and shoot it matted as `name`:
--- `open()` returns the menus to show, the first the top one, with their submenus open
--- (Stage.openSubMenu), or nil and why not. Vanilla's debug options stay out of it.
function Stage.addMenuShot(run, name, open)
    local menus
    run:add(function()
        run:newBackdrop()
        -- In debug mode vanilla adds its debug options to every world menu unless told not to.
        getDebugOptions():setBoolean("UI.HideDebugContextMenuOptions", true)
        local missing
        menus, missing = open()
        if not menus then
            run:fail(name .. ": " .. tostring(missing))
            return
        end
        -- The world menu was made when the game started, under the backdrop.
        menus[1]:bringToTop()
        return Capture.drawn(Capture.DRAW_FRAMES)
    end)
    run:addMatted(name, function()
        local left, top, right, bottom = math.huge, math.huge, 0, 0
        for _, menu in ipairs(menus) do
            left, top = math.min(left, menu:getAbsoluteX()), math.min(top, menu:getAbsoluteY())
            right = math.max(right, menu:getAbsoluteX() + menu:getWidth())
            bottom = math.max(bottom, menu:getAbsoluteY() + menu:getHeight())
        end
        return { Capture.region(name, left, top, right - left, bottom - top) }
    end)
    run:add(function()
        menus[1]:hideAndChildren()
        return 1
    end)
    run:removeBackdrop()
end

-- The groups ---------------------------------------------------------------------------------------

-- Adds a step that starts a clock, and returns a function that adds a step logging, as
-- "<mark> TIME <label> <seconds> s", how long the steps added in between took.
local function addTimer(run, label)
    local started
    run:add(function()
        started = getTimestampMs()
    end)
    return function()
        run:add(function()
            print(string.format("%s TIME %s %.1f s", run.mark, label, (getTimestampMs() - started) / 1000))
        end)
    end
end

--- Shoots the groups named in `selection` (comma-separated, in the order to shoot them, as the
--- harness gives a capture mode its MODE_GROUPS) with `run`, then writes `data` and calls done
--- (Run:run). `groups` maps each name to a function that adds its steps. `prepare(chosen)`, if
--- given, runs first with the names: it finds and builds what they need, adding steps as it
--- likes, and returns nil, or why the run can't go on, which fails it. The UI is hidden and the
--- mouse put in a corner, where it hovers over nothing a shot shows: the world outlines what it
--- is over, and menus follow it. Each group's time and the total are logged.
function Stage.runGroups(run, selection, groups, prepare, data, done)
    local chosen = Capture.names(selection)
    for _, name in ipairs(chosen) do
        if not groups[name] then
            run:fail("the mode has no group " .. name)
            return
        end
    end
    print(run.mark .. " START " .. selection)
    local endTotal = addTimer(run, "total")
    local missing = prepare and prepare(chosen)
    if missing then
        run:fail(missing)
        return
    end
    -- Hides the HUD, the debug console and every other window; the shots add their own.
    ISUIHandler.setVisibleAllUI(false)
    setMouseXY(0, 0)
    for _, name in ipairs(chosen) do
        run:group(name)
        local endGroup = addTimer(run, name)
        groups[name](name)
        endGroup()
    end
    endTotal()
    run:run(data, done)
end

return Stage
