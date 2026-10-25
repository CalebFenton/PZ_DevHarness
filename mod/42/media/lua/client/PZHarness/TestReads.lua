require "PZHarness/TestLib"
require "PZHarness/Fixtures"

-- Development only, not published. Reads of the authority's state for the test library
-- (PZHarness/TestLib.lua): answers of the dev mod's read and check handlers kept on the test, and
-- what the character carries on either side. The server halves of the checks and of the carried
-- and fill reads are in server/PZHarness/ServerChecks.lua.

local T = PZHarness.Test

-- How near a carried fluid container must come to the litres it was filled with for this client's
-- copy to count as arrived.
local FILL_LITRES = 0.01

--- The names of the overlays `object`'s tile shows on this client, in drawing order
--- (PZHarness.Fixtures.overlaysOf).
T.overlaysOf = PZHarness.Fixtures.overlaysOf

--- Queues the server handler `name` with `args`; with `label`, its answer also goes in
--- self.reads[label], so a test that reads the same handler at several points keeps each answer.
function T.read(self, name, args, label)
    T.server(self, name, args)
    if label then
        self.reads = self.reads or {}
        T.step(function() self.reads[label] = self.server[name] end)
    end
end

--- Queues calls of the server handler `name` until `done(answer)` holds or `maxMs` pass
--- (T.serverUntil), and puts the last answer in self.reads[label]: for what an action's complete()
--- does on the server after this client's perform().
function T.readUntil(self, name, args, label, done, maxMs)
    self.reads = self.reads or {}
    T.serverUntil(self, name, args, function(reply) return reply ~= nil and done(reply) end, maxMs)
    T.step(function() self.reads[label] = self.server[name] end)
end

--- Queues the server handler `name` with `args` and leaves its answer in self[key].
function T.serverInto(self, key, name, args)
    T.server(self, name, args)
    T.step(function() self[key] = self.server[name] end)
end

--- Expects a server check's answer ({ failures = { message, ... } }, PZHarness.checkHandler) to
--- have found nothing wrong; no answer at all fails too.
function T.expectNoFailures(answer)
    for _, failure in ipairs(answer and answer.failures or { "the check never answered" }) do
        T.expect(false, failure)
    end
end

--- Registers the test `testName`, which runs the server check `name` with `args` and expects it to
--- find nothing wrong.
function T.serverCheck(testName, name, args)
    T.test(testName, {
        run = function(self) T.server(self, name, args) end,
        validate = function(self) T.expectNoFailures(self.server[name]) end,
    })
end

-- What is carried -------------------------------------------------------------------------------

--- The first `fullType` this client's character carries, in any bag, or nil.
function T.carried(fullType)
    return T.player():getInventory():getFirstTypeRecurse(fullType)
end

--- Queues a wait until this client's character carries a `fullType`, failing the test as missing
--- `what` if it never does: what the server gives reaches this client after its answer.
function T.waitForCarried(self, fullType, what)
    T.waitFor(self, function() return T.carried(fullType) ~= nil end, what)
end

--- Queues reading what the authority's copy of the character carries (the PZHarness.carried
--- handler) into self.reads[label], "carried" unless given: its items of each full type in `types`
--- and the litres of each fluid in `fluids` (either may be nil). T.carriedItems and
--- T.carriedFirst read it back; the answer's `fluids` holds the litres by name and `total` the
--- number of items in the main inventory.
function T.readCarried(self, types, fluids, label)
    T.read(self, "PZHarness.carried", { types = types, fluids = fluids }, label or "carried")
end

--- The authority's items of `fullType` in the T.readCarried answer `label` ("carried" unless
--- given), in a list, empty if none or never read. Each is { id, condition, uses (the fraction
--- left), repaired (vanilla's repair count), modData, litres and tainted (a fluid container's) }.
function T.carriedItems(self, fullType, label)
    local answer = self.reads and self.reads[label or "carried"]
    return answer and answer.items and answer.items[fullType] or {}
end

--- The authority's first item of `fullType` in the T.readCarried answer `label`, or nil.
function T.carriedFirst(self, fullType, label)
    return T.carriedItems(self, fullType, label)[1]
end

--- Queues a wait until this client's first carried `fullType` holds `litres` (none when nil) of
--- fluid, or as much as it can hold: a server's fill reaches this client after its answer, and a
--- craft or a menu reads this client's copy.
function T.waitForFluid(self, fullType, litres)
    litres = litres or 0
    T.waitFor(self, function()
        local item = T.carried(fullType)
        local container = item and item:getFluidContainer()
        return container ~= nil
            and math.abs(container:getAmount() - math.min(litres, container:getCapacity())) < FILL_LITRES
    end, "this client's " .. fullType .. " holding " .. litres .. " L")
end

--- Queues emptying every fluid container of `fullType` the authority's copy of the character
--- carries and filling each with `litres` of `fluid` (a FluidType or Fluid name; nil leaves them
--- empty), through the PZHarness.fill handler, then T.waitForFluid for this client's copy.
function T.fillCarried(self, fullType, fluid, litres)
    T.server(self, "PZHarness.fill", { type = fullType, fluid = fluid, litres = fluid and litres or nil })
    T.waitForFluid(self, fullType, fluid and litres or 0)
end
