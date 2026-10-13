-- Development only, not published. What a test may leave behind in one side's copy of the game,
-- read cheaply enough to compare before and after every test: the objects on each square around
-- the character, the vehicles and powered squares among them, the character's lasting state, the
-- sandbox options, the grid, the clock and the climate overrides. Shared, so the server reads its
-- own copy the same way (the runner's leak check, client/PZHarness/Leaks.lua, and the
-- "PZHarness.snapshot" handler in server/PZHarness/ServerFixtures.lua).

PZHarness = PZHarness or {}
local Snapshot = {}
PZHarness.Snapshot = Snapshot

-- A vehicle covers a few squares each way, so every other square still finds it; a generator
-- powers a wide area, so a sparse grid of squares sees power come or go.
local VEHICLE_STRIDE = 2
local POWER_STRIDE = 4
-- Squares are keyed by one number. Basements go below level 0, so levels are shifted up.
local KEY_SPAN = 100000
local LEVEL_SHIFT = 64

--- Lua patterns over an object's "<look>@<class>" that the comparison leaves out: the world
--- changes these by itself as time passes (crops grow, wilt and die; erosion spreads grass,
--- plants, trees, cracks and snow), and grass goes from a square something is placed on, which
--- nothing puts back. A dev mod adds its own with the `leakIgnore` setting.
Snapshot.DEFAULT_IGNORE = {
    "^vegetation_farming", "^vegetation_gardening", "^blends_grassoverlays", "^e_", "^d_plants",
    "^d_generic", "^d_floorleaves", "^d_trash", "^d_streetcracks", "^d_wallcracks", "^f_bushes",
    "^f_flowerbed", "^f_wallvines",
}

local function squareKey(x, y, z)
    return ((z + LEVEL_SHIFT) * KEY_SPAN + y) * KEY_SPAN + x
end

local function keyCoordinates(key)
    return key % KEY_SPAN, math.floor(key / KEY_SPAN) % KEY_SPAN, math.floor(key / (KEY_SPAN * KEY_SPAN)) - LEVEL_SHIFT
end

--- "x,y,z" for a square key.
function Snapshot.where(key)
    local x, y, z = keyCoordinates(key)
    return x .. "," .. y .. "," .. z
end

-- One object as "<look>@<class>": the sprite, or a world item's type, with "*" while a generator
-- or light switch is on. getObjectName is the class for the classes that override it, and the
-- object's name or "IsoObject" otherwise.
local function objectToken(object)
    local class = object:getObjectName()
    local look
    if class == "WorldInventoryItem" then
        local item = object:getItem()
        look = "item:" .. (item and item:getFullType() or "?")
    else
        look = object:getTextureName() or "-"
    end
    if (class == "IsoGenerator" or class == "LightSwitch") and object:isActivated() then
        look = look .. "*"
    end
    return look .. "@" .. class
end

-- Whether each token is ignored, worked out once per token and ignore list, since the same few
-- sprites cover most squares and every pattern costs a string search.
local ignoreKey, ignorePatterns, ignoreCache

local function useIgnore(patterns)
    local key = table.concat(patterns, "\n")
    if key ~= ignoreKey then
        ignoreKey, ignorePatterns, ignoreCache = key, patterns, {}
    end
end

local function ignored(token)
    local hit = ignoreCache[token]
    if hit == nil then
        hit = false
        for _, pattern in ipairs(ignorePatterns) do
            if string.find(token, pattern) then
                hit = true
                break
            end
        end
        ignoreCache[token] = hit
    end
    return hit
end

local function squareSignature(square)
    local objects = square:getObjects()
    local count = objects:size()
    if count == 1 then
        local token = objectToken(objects:get(0))
        return ignored(token) and "" or token
    end
    local tokens = {}
    for i = 0, count - 1 do
        local token = objectToken(objects:get(i))
        if not ignored(token) then
            tokens[#tokens + 1] = token
        end
    end
    return table.concat(tokens, ";")
end

--- The signature of the square with key `key` in this game now, leaving out what `ignore`
--- matches, or false if it isn't loaded.
function Snapshot.signatureAt(key, ignore)
    useIgnore(ignore)
    local square = getCell():getGridSquare(keyCoordinates(key))
    return square and squareSignature(square) or false
end

--- A square's signature as the other side's copy should have it too: the looks without the
--- classes, since a name given on one side need not travel.
function Snapshot.syncSignature(signature)
    return (string.gsub(signature, "@[^;]*", ""))
end

local function sandboxValues(state)
    for key, value in pairs(SandboxVars) do
        if type(value) == "table" then
            for inner, innerValue in pairs(value) do
                if type(innerValue) ~= "table" and type(innerValue) ~= "function" then
                    state["sandbox " .. key .. "." .. inner] = tostring(innerValue)
                end
            end
        elseif type(value) ~= "function" then
            state["sandbox " .. key] = tostring(value)
        end
    end
end

-- A multiplayer client's perk levels and known recipes are copies the server sends when it likes,
-- so only the server's count there.
local function characterState(state, character, copy)
    if not copy then
        for i = 0, PerkFactory.PerkList:size() - 1 do
            local perk = PerkFactory.PerkList:get(i)
            state["perk " .. perk:getId()] = character:getPerkLevel(perk)
        end
        state["known recipes"] = character:getKnownRecipes():size()
    end
    state["inventory items after the reset"] = character:getInventory():getItems():size()
    state["worn items after the reset"] = character:getWornItems():size()
    local primary, secondary = character:getPrimaryHandItem(), character:getSecondaryHandItem()
    state["primary hand after the reset"] = primary and primary:getFullType() or "nothing"
    state["secondary hand after the reset"] = secondary and secondary:getFullType() or "nothing"
end

local function worldState(state)
    state["the grid"] = getWorld():isHydroPowerOn() and "on" or "off"
    local shut = getSandboxOptions():getOptionByName("ElecShutModifier")
    if shut then
        state["the grid's shutoff day"] = tostring(shut:getValue())
    end
    state["the game speed"] = getGameTime():getTrueMultiplier()
    local climate = getClimateManager()
    for i = 0, climate:getFloatMax() - 1 do
        local float = climate:getClimateFloat(i)
        if float:isEnableAdmin() then
            state["the admin override of climate float " .. i] = float:getAdminValue()
        end
    end
    sandboxValues(state)
end

--- What `opts` covers in this game: the squares within `opts.radius` of x, y on each of
--- `opts.levels` (z levels), leaving out the objects `opts.ignore` matches, and, with
--- `character`, that character's state; `opts.copy` leaves out what a multiplayer client only
--- copies from the server. Squares that aren't loaded are left out.
function Snapshot.take(opts, character)
    useIgnore(opts.ignore)
    local snapshot = {
        x = opts.x, y = opts.y, z = opts.z,
        squares = {}, vehicles = {}, powered = {}, state = {},
        worldHours = getGameTime():getWorldAgeHours(),
        realMs = getTimestampMs(),
        minutesPerDay = getGameTime():getMinutesPerDay(),
    }
    local cell, squares, vehicles, powered = getCell(), snapshot.squares, snapshot.vehicles, snapshot.powered
    local r = opts.radius
    for _, z in ipairs(opts.levels) do
        for x = opts.x - r, opts.x + r do
            for y = opts.y - r, opts.y + r do
                local square = cell:getGridSquare(x, y, z)
                if square then
                    local key = squareKey(x, y, z)
                    squares[key] = squareSignature(square)
                    if x % VEHICLE_STRIDE == 0 and y % VEHICLE_STRIDE == 0 then
                        local vehicle = square:getVehicleContainer()
                        if vehicle then
                            vehicles[vehicle:getId()] = vehicle:getScriptName()
                        end
                    end
                    if x % POWER_STRIDE == 0 and y % POWER_STRIDE == 0 then
                        powered[key] = square:haveElectricity()
                    end
                end
            end
        end
    end
    worldState(snapshot.state)
    if character then
        characterState(snapshot.state, character, opts.copy)
    end
    return snapshot
end

-- The clock runs between two snapshots; a test that set it and didn't set it back moves it much
-- further, or back. Slack for a test that sets its own hour and puts the clock back.
local CLOCK_SLACK_HOURS = 0.25

local function clockLine(before, after)
    local seconds = (after.realMs - before.realMs) / 1000
    local expected = seconds / (before.minutesPerDay * 60) * 24
    local moved = after.worldHours - before.worldHours
    if math.abs(moved - expected) > math.max(CLOCK_SLACK_HOURS, expected * 2) then
        return string.format("the clock moved %.2f hours in %.1f s of real time", moved, seconds)
    end
    return nil
end

local function powerLines(lines, before, after)
    local gained, lost, gainedAt, lostAt = 0, 0, nil, nil
    for key, now in pairs(after.powered) do
        local was = before.powered[key]
        if was ~= nil and was ~= now then
            if now then
                gained, gainedAt = gained + 1, gainedAt or key
            else
                lost, lostAt = lost + 1, lostAt or key
            end
        end
    end
    if gained > 0 then
        table.insert(lines, gained .. " sampled squares gained power, such as " .. Snapshot.where(gainedAt))
    end
    if lost > 0 then
        table.insert(lines, lost .. " sampled squares lost power, such as " .. Snapshot.where(lostAt))
    end
end

--- What differs from `before` to `after`, as readable lines: `squares` (with the keys of those
--- squares in `changed`), `vehicles`, and `other` (power, the character's start and state, the
--- options, the grid, the climate, and the clock unless `opts.clock` is false). Squares loaded in
--- only one of them are left out. A snapshot around another square compares only what isn't on
--- the squares.
function Snapshot.diff(before, after, opts)
    local report = { squares = {}, vehicles = {}, other = {}, changed = {} }
    if before.x ~= after.x or before.y ~= after.y or before.z ~= after.z then
        table.insert(report.other, string.format("the character starts at %d,%d,%d, not %d,%d,%d where the test began",
            after.x, after.y, after.z, before.x, before.y, before.z))
    else
        for key, signature in pairs(after.squares) do
            local was = before.squares[key]
            if was and was ~= signature then
                table.insert(report.changed, key)
                table.insert(report.squares, "square " .. Snapshot.where(key) .. " holds [" .. signature .. "], was [" .. was .. "]")
            end
        end
        for id, script in pairs(after.vehicles) do
            if not before.vehicles[id] then
                table.insert(report.vehicles, "a " .. script .. " (vehicle " .. id .. ") is still there")
            end
        end
        for id, script in pairs(before.vehicles) do
            if not after.vehicles[id] then
                table.insert(report.vehicles, "the " .. script .. " (vehicle " .. id .. ") that stood there is gone")
            end
        end
        powerLines(report.other, before, after)
    end
    for key, value in pairs(after.state) do
        if before.state[key] ~= value then
            table.insert(report.other, key .. " is " .. tostring(value) .. ", was " .. tostring(before.state[key] or "unset"))
        end
    end
    for key, value in pairs(before.state) do
        if after.state[key] == nil then
            table.insert(report.other, key .. " is unset, was " .. tostring(value))
        end
    end
    local clock = not (opts and opts.clock == false) and clockLine(before, after)
    if clock then
        table.insert(report.other, clock)
    end
    return report
end

--- Every line of a diff's report, each after `prefix` (if given), appended to `lines`.
function Snapshot.addLines(lines, report, prefix)
    for _, kind in ipairs({ "squares", "vehicles", "other" }) do
        for _, line in ipairs(report[kind]) do
            table.insert(lines, (prefix or "") .. line)
        end
    end
    return lines
end

return Snapshot
