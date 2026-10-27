require "PZHarness/TestWorld"
require "PZHarness/TestReads"

-- Development only, not published. The record kit: fixtures, sets and reads of the records of a
-- mod's Global Object Systems, which live on the authority, for every kind the `records` test
-- setting names (server/PZHarness/ServerRecords.lua says what a kind gives). A record handle is a
-- T.where handle with its `kind`; `object` is this client's copy of its tile once it has one. The
-- reads land in self.reads[label] when given, and in handle.state, the last the test read of it.
local T = PZHarness.Test

-- The server args of the record `handle`: its kind and place, with `extra`'s fields.
local function recordArgs(handle, extra)
    local args = T.at(handle, extra)
    args.kind = handle.kind
    return args
end

-- Queues the server handler `name` on the record `handle` with `extra`'s args; its answer lands in
-- self.reads[label] when given and in handle.state.
local function readOn(self, handle, name, extra, label)
    T.read(self, name, recordArgs(handle, extra), label)
    T.step(function() handle.state = self.server[name] end)
end

--- This client's summary of the record `handle` (its kind's owner's summaryOf of T.copyOf), or nil.
function T.recordSummary(handle)
    local copy = T.copyOf(handle)
    return copy and PZHarness.testSettings.records[handle.kind].owner().summaryOf(copy)
end

--- Queues a wait until this client's summary of the record `handle` satisfies `check(summary)`;
--- missing `what` if it never does.
function T.waitForSummary(self, handle, check, what)
    T.waitFor(self, function()
        local summary = T.recordSummary(handle)
        return summary ~= nil and check(summary)
    end, what)
end

--- Queues a record of `kind` built by its kind's `build` on the tile `tile` (whatever the kind
--- takes) on `opts.square`, else on a free square (outdoors unless `opts.indoors`) near
--- `opts.near`, at least `opts.minDistance` away; removed with its record when the test ends; and
--- a wait for this client's copy with its summary. Returns its handle, or nil without a square.
function T.placeRecord(self, kind, tile, opts)
    opts = opts or {}
    local square = opts.square or T.square(self, { indoors = opts.indoors, near = opts.near, minDistance = opts.minDistance },
        "a free square for a " .. kind)
    if not square then return nil end
    local handle = T.where(square)
    handle.kind = kind
    T.server(self, "PZHarness.placeRecord", recordArgs(handle, { tile = tile }), function()
        handle.object = T.copyOf(handle)
        return handle.object ~= nil and T.recordSummary(handle) ~= nil
    end, "this client's copy of the " .. kind)
    return handle
end

--- Queues setting the record's saved fields `fields` as of now, and those of `ago` ({ [field] =
--- hours }) to the world hour that many hours before the server runs it; its last pass is then
--- now, and it shows and tells what changed. A name that isn't a saved field fails the test.
function T.setRecord(self, handle, fields, ago)
    T.server(self, "PZHarness.setRecord", recordArgs(handle, { fields = fields, ago = ago }))
end

--- Queues putting `items` in the record's containers as a player's transfer does: { [container
--- name] = { { type, count, rotten } } }, by the names its kind's `containers` gives.
function T.fillRecord(self, handle, items)
    T.server(self, "PZHarness.fillRecord", recordArgs(handle, { items = items }))
end

--- Queues the record's own pass, as though `hours` had passed since its last, loaded or not; its
--- read after lands as T.readRecord's.
function T.ageRecord(self, handle, hours, label)
    readOn(self, handle, "PZHarness.ageRecord", { hours = hours }, label)
end

--- Queues a read of the record: its saved fields, whether its tile is `loaded`, and while it is
--- its `sprite`, `overlays` and `summary`, with what its kind's `extras` add. With `rewind`, its
--- last pass is first put that many hours before now, as a record no pass has reached for that
--- long looks.
function T.readRecord(self, handle, label, rewind)
    readOn(self, handle, "PZHarness.readRecord", { rewind = rewind }, label)
end

--- Queues the record saved and loaded again, as quitting and continuing the game leaves it, with
--- the reads `reads` ({ [label] = { name = handler, args } }) taken before and after in the same
--- call; the answer { before, after, state } lands in self.reads[label] when given.
function T.reloadRecord(self, handle, label, reads)
    T.read(self, "PZHarness.reloadRecord", recordArgs(handle, { reads = reads }), label)
end

--- Queues the dev mod's handler `name` on the record `handle`, with `args` (a table) added to its
--- kind and place; the answer, the record's state, lands as T.readRecord's.
function T.onRecord(self, handle, name, args, label)
    readOn(self, handle, name, args, label)
end

return T
