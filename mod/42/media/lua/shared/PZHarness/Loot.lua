-- Development only, not published. The loot tables and the game's own loot rolls, for a dev mod's
-- loot checks (server handlers, where the loot tables are filled) and its loot report mode (which
-- rolls on the client in single player): walking the tables, rolling scratch containers that never
-- enter the world, and the sandbox options to measure at. Shared so both sides roll the same way.
-- The mod's loot schema and labels stay in the dev mod.

require "PZHarness/Fixtures"

PZHarness = PZHarness or {}
local Loot = {}
PZHarness.Loot = Loot

-- ItemPickerJava.getItemContainer reaches a parsed table only through a room, so withParsed files
-- the tables it parses under this made-up one.
local PROBE_ROOM = "PZHarnessLootProbe"
-- How far squareOutsideRooms looks, in squares.
local OUTDOOR_SEARCH = 40
-- How many tables deep forEachItemsList walks: a bound on a runaway walk, as `seen` stops cycles.
local WALK_DEPTH = 6

--- In an options table of Loot.withMeasureOptions, stands for the option's default value, which the
--- game takes from the Apocalypse preset (SandboxOptions constructor).
Loot.DEFAULT = {}

--- Returns fn()'s result, calling restore() after fn whether or not it throws; a throw goes on
--- after restore, so a failed measurement still leaves the game's loot and options as they were.
function Loot.restoring(fn, restore)
    local ok, result = pcall(fn)
    restore()
    if not ok then
        error(result)
    end
    return result
end

--- Calls fn(items, path) for every `items` list of every room, container, bag, procedural and
--- vehicle table, `path` naming where it is ("SuburbsDistributions.bedroom.wardrobe").
function Loot.forEachItemsList(fn)
    local seen = {}
    local function walk(t, path, depth)
        if seen[t] or depth > WALK_DEPTH then
            return
        end
        seen[t] = true
        if type(t.items) == "table" then
            fn(t.items, path)
        end
        for key, value in pairs(t) do
            if type(value) == "table" and key ~= "items" and key ~= "procList" then
                walk(value, path .. "." .. tostring(key), depth + 1)
            end
        end
    end
    walk(SuburbsDistributions, "SuburbsDistributions", 0)
    walk(ProceduralDistributions.list, "ProceduralDistributions", 0)
    walk(VehicleDistributions, "VehicleDistributions", 0)
end

--- The first room and container type whose procList picks each ProceduralDistributions list:
--- list name -> { room, container }. Only procedural containers count: getItemContainer answers
--- the container's own table for any other, which would pass for the list.
function Loot.procListUsers()
    local users = {}
    for roomName, room in pairs(SuburbsDistributions) do
        if type(room) == "table" then
            for containerType, containerTable in pairs(room) do
                if type(containerTable) == "table" and containerTable.procedural and type(containerTable.procList) == "table" then
                    for _, choice in ipairs(containerTable.procList) do
                        if choice.name and not users[choice.name] then
                            users[choice.name] = { room = roomName, container = containerType }
                        end
                    end
                end
            end
        end
    end
    return users
end

--- The game's parsed copy of ProceduralDistributions list `name`, to roll with Loot.rollFill, and
--- the user (Loot.procListUsers, or `users` if given) it was reached through; nil when no
--- container picks it or the game never parsed it. getItemContainer finds a list only through a
--- room and container type that pick it.
function Loot.proceduralList(name, users)
    local user = (users or Loot.procListUsers())[name]
    local list = user and ItemPickerJava.getItemContainer(user.room, user.container, name, false)
    if not list then
        return nil
    end
    return list, user
end

--- The name of the loot rarity option that scales the item `fullType`, and the option: the one
--- vanilla reads for the item's loot type (ItemPickerJava.getLootType, getLootModifierFromType),
--- "<type>LootNew", or "<type>Loot" for the books' types. Else nil and the loot type.
function Loot.rarityOf(fullType)
    local item = getScriptManager():getItem(fullType)
    local lootType = item and ItemPickerJava.getLootType(item)
    if not lootType then
        return nil, nil
    end
    local options = getSandboxOptions()
    for _, name in ipairs({ lootType .. "LootNew", lootType .. "Loot" }) do
        local option = options:getOptionByName(name)
        if option then
            return name, option
        end
    end
    return nil, lootType
end

--- Runs fn() with the game's sandbox options `options` (option name -> value, or Loot.DEFAULT) and
--- the General debug log off, and returns its result; puts both back afterwards, even when fn
--- throws. In debug mode ItemPickInfo logs a line for every roll into a container that isn't on a
--- square, which floods console.txt. The loot category multipliers are cached when a game loads
--- (ItemPickerJava.InitSandboxLootSettings), so they are reloaded on both sides of fn.
function Loot.withMeasureOptions(options, fn)
    local sandbox = getSandboxOptions()
    local saved = {}
    local generalLog = DebugType.General:getLogSeverity()
    return Loot.restoring(function()
        for name, value in pairs(options) do
            local option = sandbox:getOptionByName(name)
            saved[name] = option:getValue()
            option:setValue(value == Loot.DEFAULT and option:getDefaultValue() or value)
        end
        ItemPickerJava.InitSandboxLootSettings()
        DebugType.General:setLogSeverity(LogSeverity.Off)
        return fn()
    end, function()
        DebugType.General:setLogSeverity(generalLog)
        for name, value in pairs(saved) do
            sandbox:getOptionByName(name):setValue(value)
        end
        ItemPickerJava.InitSandboxLootSettings()
    end)
end

--- Runs fn(parsed) with `containers` (key -> container table, as a room's in SuburbsDistributions)
--- and `lists` (optional, name -> ProceduralDistributions list for the procedural ones to pick)
--- parsed by the game, and returns its result. parsed[key] is the game's copy of the container, to
--- roll with Loot.rollFill, or nil if the game didn't take it. Afterwards takes both out and parses
--- the loot again, even when fn throws.
function Loot.withParsed(containers, lists, fn)
    lists = lists or {}
    return Loot.restoring(function()
        for name, list in pairs(lists) do
            ProceduralDistributions.list[name] = list
        end
        SuburbsDistributions[PROBE_ROOM] = containers
        ItemPickerJava.Parse()
        local parsed = {}
        for key, containerTable in pairs(containers) do
            -- For a procedural container, a list name no entry has returns the container itself.
            parsed[key] = ItemPickerJava.getItemContainer(PROBE_ROOM, key, containerTable.procedural and "" or nil, false)
        end
        return fn(parsed)
    end, function()
        SuburbsDistributions[PROBE_ROOM] = nil
        for name in pairs(lists) do
            ProceduralDistributions.list[name] = nil
        end
        ItemPickerJava.Parse()
    end)
end

--- A fill for Loot.fillOnce and Loot.sample: rolls the parsed container or list `list` into the
--- container as the game fills one (ItemPickerJava.rollItem: the junk list, then the items).
function Loot.rollFill(list)
    return function(container)
        ItemPickerJava.rollItem(list, container, true, nil, nil)
    end
end

--- The items in the container, bags' and boxes' contents included, as fullType -> count, of the
--- types `matches(fullType)` takes, or of every type without it; added to `counts` if given.
function Loot.countItems(container, matches, counts)
    counts = counts or {}
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local fullType = item:getFullType()
        if not matches or matches(fullType) then
            counts[fullType] = (counts[fullType] or 0) + 1
        end
        if item:IsInventoryContainer() then
            Loot.countItems(item:getInventory(), matches, counts)
        end
    end
    return counts
end

--- Takes the container's items, bags' and boxes' contents included, off the cell's processed items
--- (`processItems`, by default getCell():getProcessItems()), where ItemContainer.AddItem puts every
--- new item. Thousands of fills in one frame pile up there until the game runs out of memory.
function Loot.forgetItems(container, processItems)
    processItems = processItems or getCell():getProcessItems()
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        processItems:remove(item)
        if item:IsInventoryContainer() then
            Loot.forgetItems(item:getInventory(), processItems)
        end
    end
end

--- Empties `container`, calls fill(container), and returns read(container): by default
--- Loot.countItems of every item. Then forgets (Loot.forgetItems) and empties what the fill made,
--- so any number of fills fit in memory.
function Loot.fillOnce(fill, container, read)
    container:removeAllItems()
    fill(container)
    local result = (read or Loot.countItems)(container)
    Loot.forgetItems(container)
    container:removeAllItems()
    return result
end

--- Fills `container` `samples` times with Loot.fillOnce(fill, container, read), `read` answering
--- key -> count (by default fullType -> count of every item). Returns key -> { share = fraction of
--- samples with a count above 0, perContainer = mean count in those }.
function Loot.sample(fill, samples, container, read)
    local holding, total = {}, {}
    for _ = 1, samples do
        for key, count in pairs(Loot.fillOnce(fill, container, read)) do
            if count > 0 then
                holding[key] = (holding[key] or 0) + 1
                total[key] = (total[key] or 0) + count
            end
        end
    end
    local result = {}
    for key, n in pairs(holding) do
        result[key] = { share = n / samples, perContainer = total[key] / n }
    end
    return result
end

--- The loaded ground-floor square nearest `character` that is in no room, or nil. A procedural
--- table rolls only into a container on a square, and one in a room counts toward the room's
--- per-room list limits and gets its forced lists.
function Loot.squareOutsideRooms(character)
    local cell = getCell()
    if not character or not cell then
        return nil
    end
    local px, py = math.floor(character:getX()), math.floor(character:getY())
    for radius = 0, OUTDOOR_SEARCH do
        for x, y in PZHarness.Fixtures.ring(px, py, radius) do
            local square = cell:getGridSquare(x, y, 0)
            if square and square:getRoom() == nil then
                return square
            end
        end
    end
    return nil
end

--- A crate that never enters the world, to fill and read. Give it a square from
--- Loot.squareOutsideRooms to roll procedural tables into it, or nil for anything else.
---@param square IsoGridSquare?
function Loot.scratchContainer(square)
    return ItemContainer.new("crate", square, nil)
end

--- A share of samples as "<percent>% (1 in <n>)", with `percentPlaces` and `oneInPlaces`
--- decimals, or "none" when nothing came.
function Loot.share(fraction, percentPlaces, oneInPlaces)
    if fraction <= 0 then
        return "none"
    end
    return string.format("%." .. percentPlaces .. "f%% (1 in %." .. oneInPlaces .. "f)", fraction * 100, 1 / fraction)
end

return Loot
