require "PZHarness/ServerHandlers"
require "PZHarness/ServerFixtures"
require "PZHarness/Fixtures"

-- Development only, not published. The authority's half of the record kit
-- (client/PZHarness/TestRecords.lua). Written against the record contract cf_commonlib's
-- ObjectSystem and GlobalObjects keep, by method name, so it needs no library: a record has its
-- class's SAVED_FIELDS, lastHour (the world hour time last reached it), update() (a pass up to now)
-- and afterChange() (shows and tells what changed), and its system (record.luaSystem) rebuilds
-- records from what a save keeps (initLuaObjects). Each kind of the `records` test setting is
-- { owner(), build(square, tile)?, containers(object)?, extras(record, object, state)? }: the
-- shared module with feature.isObject, recordAt, summaryOf and currentSummary; a build as the build
-- menu's; the containers by name ({ hopper = ... }); and what a read adds, object nil unloaded.
-- A record is named by its kind and its tile's place, { kind, x, y, z }, loaded or not.

PZHarness = PZHarness or {}
local Records = {}
PZHarness.Records = Records

local Fixtures = PZHarness.Fixtures
local handler, need = PZHarness.serverHandler, PZHarness.need

local function now()
    return getGameTime():getWorldAgeHours()
end

--- The `records` setting's spec of `kind`, or the running handler ends as missing it.
function Records.kind(kind)
    local records = PZHarness.testSettings.records
    return need(records and records[kind], "the record kind " .. tostring(kind) .. " in the records test setting")
end

--- The record of kind `at.kind` at x, y, z, loaded or not, and its tile while loaded; the running
--- handler ends as missing a record.
function Records.at(at)
    local record = need(Records.kind(at.kind).owner().recordAt(at.x, at.y, at.z),
        "a " .. tostring(at.kind) .. " record at " .. at.x .. "," .. at.y .. "," .. at.z .. " on the server")
    return record, record:getIsoObject()
end

--- Sets `fields` (saved field = value) on `record`, each saved field of `ago` (field = hours) to the
--- world hour that many hours before now, and, given `lastHoursAgo`, its lastHour that many hours
--- before now. Every name must be one of the record's SAVED_FIELDS: a misspelled one would sit
--- beside the field the code reads and change nothing, so the running handler ends as missing it.
--- Shows and tells nothing.
function Records.set(record, fields, ago, lastHoursAgo)
    local saved = {}
    for _, field in ipairs(record.SAVED_FIELDS) do
        saved[field] = true
    end
    for _, names in ipairs({ fields or {}, ago or {} }) do
        for key in pairs(names) do
            need(saved[key], "a saved field " .. tostring(key) .. " of the record")
        end
    end
    local hour = now()
    for key, value in pairs(fields or {}) do
        record[key] = value
    end
    for key, hours in pairs(ago or {}) do
        record[key] = hour - hours
    end
    if lastHoursAgo then
        record.lastHour = hour - lastHoursAgo
    end
end

--- The record of kind `kind` as plain values: its saved fields; whether its tile is `loaded`;
--- while it is (`object`), its `sprite`, `overlays` and the `summary` this side builds; and what
--- the kind's `extras` add.
function Records.read(kind, record, object)
    local spec = Records.kind(kind)
    local state = Fixtures.fieldsOf(record, record.SAVED_FIELDS)
    state.loaded = object ~= nil
    if object then
        local sprite = object:getSprite()
        state.sprite = sprite and sprite:getName()
        state.overlays = Fixtures.overlaysOf(object)
        state.summary = spec.owner().currentSummary(object)
    end
    if spec.extras then
        spec.extras(record, object, state)
    end
    return state
end

--- Has what the test leaves on the square at `at` ({ kind, x, y, z }) go when it ends
--- (PZHarness.trackSquare, for `player`), and the record of kind `at.kind` there if it outlives its
--- tile, as one whose tile went while its chunk was away does.
function Records.track(defer, player, at)
    local owner = Records.kind(at.kind).owner()
    local had = owner.recordAt(at.x, at.y, at.z)
    defer(function()
        local record = owner.recordAt(at.x, at.y, at.z)
        if record and record ~= had then
            record.luaSystem:removeLuaObject(record)
        end
    end)
    PZHarness.trackSquare(defer, player, at)
end

-- T.placeRecord, removed with its record when the test ends (Records.track).
handler("PZHarness.placeRecord", function(player, args, defer)
    local build = need(Records.kind(args.kind).build, "a build of the record kind " .. args.kind)
    Records.track(defer, player, args)
    build(PZHarness.squareAt(args), args.tile)
    return {}
end)

-- T.setRecord, its lastHour now.
handler("PZHarness.setRecord", function(_, args)
    local record = Records.at(args)
    Records.set(record, args.fields, args.ago, 0)
    -- The record's class is the mod's, which a mod without records (and its static check) lacks.
    record.afterChange(record)
    return {}
end)

-- T.fillRecord: past the containers' filters, as a player's transfer would; the record hears of it
-- only in its next pass.
handler("PZHarness.fillRecord", function(_, args)
    local _, object = Records.at(args)
    local containersOf = need(Records.kind(args.kind).containers, "the containers of the record kind " .. args.kind)
    local containers = containersOf(need(object, "the " .. args.kind .. "'s tile loaded on the server"))
    for name, entries in pairs(args.items) do
        local container = need(containers[name], "a " .. name .. " on the " .. args.kind)
        for _, entry in ipairs(entries) do
            for _ = 1, entry.count or 1 do
                local item = need(instanceItem(entry.type), "an item " .. tostring(entry.type))
                if entry.rotten then
                    item:setAge(item:getOffAgeMax() + 1)
                end
                container:AddItem(item)
                sendAddItemToContainer(container, item)
            end
        end
    end
    return {}
end)

-- T.ageRecord. Answers its read, from the record alone while its tile is unloaded.
handler("PZHarness.ageRecord", function(_, args)
    local record = Records.at(args)
    record.lastHour = now() - args.hours
    record:update()
    return Records.read(args.kind, record, record:getIsoObject())
end)

-- T.readRecord.
handler("PZHarness.readRecord", function(_, args)
    local record, object = Records.at(args)
    if args.rewind then
        record.lastHour = now() - args.rewind
    end
    return Records.read(args.kind, record, object)
end)

-- T.reloadRecord: the Global Object System saves only its SAVED_FIELDS (SGlobalObject.save), so
-- every other field goes, and on load its system builds its records from what was saved
-- (initLuaObjects). Answers `before`, `after` (PZHarness.readsAround) and the loaded record's read,
-- `state`.
handler("PZHarness.reloadRecord", function(player, args, defer)
    local record = Records.at(args)
    local before, after = PZHarness.readsAround(player, args.reads, defer, function()
        local system, saved, gone = record.luaSystem, {}, {}
        for _, key in ipairs(record.SAVED_FIELDS) do
            saved[key] = true
        end
        for key in pairs(record) do
            if not saved[key] then
                table.insert(gone, key)
            end
        end
        for _, key in ipairs(gone) do
            record[key] = nil
        end
        system:initLuaObjects()
    end)
    local loaded, object = Records.at(args)
    return { before = before, after = after, state = Records.read(args.kind, loaded, object) }
end)

return Records
