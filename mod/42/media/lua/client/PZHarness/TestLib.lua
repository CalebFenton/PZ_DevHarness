require "Tests/TimedActionsTests"
require "PZHarness/Runner"
require "PZHarness/Fixtures"
require "PZHarness/Checks"

-- The generic half of a mod's test library. A mod's own library inherits from it
-- (setmetatable(ModTest, { __index = PZHarness.Test })) and adds fixtures for the mod's objects;
-- test files register with vanilla's timed action test runner through T.test. The runner (debug
-- menu or PZHarness/Runner.lua) calls run(), waits for the action queue to empty, then calls
-- validate(). It resets inventory, hands, worn items and position between tests; nothing else.
--
-- Settings and hooks come from the dev mod's PZHarness.registerTests (see
-- shared/PZHarness/Fixtures.lua).
--
-- Rules of the API, so that no test depends on what an earlier one left:
-- - T.test gives every run a fresh `self` and applies the spec's hour, `instant` and `sandbox`.
-- - Every setter, T.defer, T.onTick and fixture pushes its undo onto the test's restore stack,
--   which the wrapper unwinds newest first after validate and `spec.cleanup`.
-- - A fixture that can't be built records what is missing (T.need); the wrapper then fails the
--   test with it and skips spec.validate, so validate never indexes a missing fixture.
-- - A Lua error stops the game in the debug-mode error handler, pcall or not, and the runner never
--   finishes, so tests never throw.
--
-- Single player and multiplayer run the same tests. On a multiplayer client the world is the
-- client's copy, so authority-only work goes through T.server, which calls a handler the dev mod
-- registered (server/PZHarness/ServerHandlers.lua) locally in single player or on the server in
-- multiplayer. A test that can't run in one mode says so with `spOnly = "<why>"` or
-- `mpOnly = "<why>"`, and the runner skips it there.
-- World fixtures are in TestWorld, recipes/learning in TestLearning, and craft helpers in
-- TestCraft. Require the feature a caller uses; the core does not load them implicitly.
PZHarness.Test = {}
local T = PZHarness.Test

-- Squares searched around a fixture's centre, in tiles. The runner's leak check looks a little
-- further by default.
local SEARCH_RADIUS = 30
T.SEARCH_RADIUS = SEARCH_RADIUS

local function settings()
    return PZHarness.testSettings
end

function T.player()
    return getSpecificPlayer(0)
end

-- Expectations

-- Unmet expectations of the test being validated.
local failures = {}

function T.expect(condition, message)
    if not condition then
        table.insert(failures, message)
    end
    return condition
end

function T.expectNear(label, actual, expected, tolerance)
    local ok, message = PZHarness.Checks.near(label, actual, expected, tolerance)
    return T.expect(ok, message)
end

function T.expectEqual(label, actual, expected)
    local ok, message = PZHarness.Checks.equal(label, actual, expected)
    return T.expect(ok, message)
end

--- Returns `value`; when it is nil or false, records `what` (a noun phrase: "a free indoor square
--- for a table") as missing, which fails the test without running spec.validate.
function T.need(self, value, what)
    if not value then
        table.insert(self.missing, what)
    end
    return value
end

local Runtime = require "PZHarness/TestRuntime"

-- Restore stack

--- Runs `undo` when the test ends, before the undos pushed earlier.
function T.defer(self, undo)
    table.insert(self.undo, undo)
end

--- Calls `fn` every tick until the test ends.
function T.onTick(self, fn)
    Events.OnTick.Add(fn)
    T.defer(self, function() Events.OnTick.Remove(fn) end)
end

-- The setters below are two-sided: they change this game's copy at once, and on a multiplayer
-- client the server's copy too (Runtime.alsoOnServer), which the server undoes when the test ends.

function T.setTime(self, hour)
    T.defer(self, PZHarness.Fixtures.setTime(hour))
    Runtime.alsoOnServer(self, "PZHarness.setTime", { hour = hour }, function()
        -- A clock sync the server sent before it changed the time may have come in since.
        getGameTime():setTimeOfDay(hour)
    end)
end

--- Sets the character's level of `perk` for the test. On a multiplayer client a periodic server
--- perk sync (PlayerXpPacket) sent before the change can land after the answer and revert the
--- level, so until the test ends the client reapplies it whenever a sync changes it.
function T.setPerk(self, perk, level)
    local p = T.player()
    T.defer(self, PZHarness.Fixtures.setPerk(p, perk, level))
    Runtime.alsoOnServer(self, "PZHarness.setPerk", { perk = perk:getId(), level = level })
    if isClient() then
        T.onTick(self, function()
            if p:getPerkLevel(perk) ~= level then
                p:setPerkLevelDebug(perk, level)
            end
        end)
    end
end

local function sandboxChanged()
    if settings().sandboxChanged then
        settings().sandboxChanged()
    end
end

--- Sets a sandbox option of the mod (SandboxVars[settings.sandbox]) or, failing that, of the
--- game, in SandboxVars and in the game's own copy. An option in neither is recorded as missing
--- rather than created. Each side calls the `sandboxChanged` setting after its copy changes.
function T.setSandbox(self, key, value)
    local options, name = PZHarness.Fixtures.sandboxOptions(settings().sandbox, key)
    if not T.need(self, options, "the sandbox option " .. key) then return end
    T.defer(self, PZHarness.Fixtures.setSandbox(options, name, key, value, sandboxChanged))
    Runtime.alsoOnServer(self, "PZHarness.setSandbox", { table = settings().sandbox, key = key, value = value })
end

--- The game runs `multiplier` times as fast: the clock and every timed action alike. The game drops
--- back to 1 when the character moves without a path or a zombie comes close.
function T.setMultiplier(self, multiplier)
    T.defer(self, PZHarness.Fixtures.setMultiplier(multiplier))
    Runtime.alsoOnServer(self, "PZHarness.setMultiplier", { multiplier = multiplier })
end

--- Vanilla's mechanics cheat on or off for the character, on both sides (Fixtures.setMechanicsCheat).
--- A multiplayer server times a vehicle part's install and uninstall in real time, and the instant
--- cheat can't shorten them there: an instant action on a client checks isValid again once the
--- server has moved the part, fails, and empties the action queue. The mechanics cheat skips that
--- check, so a test turns it on around the action, after reading canInstallPart and
--- canUninstallPart itself.
function T.setMechanicsCheat(self, on)
    T.defer(self, PZHarness.Fixtures.setMechanicsCheat(T.player(), on))
    Runtime.alsoOnServer(self, "PZHarness.setMechanicsCheat", { on = on })
end

--- Vanilla's ISInstallVehiclePart:new takes its time from its caller (ISVehiclePartMenu.onInstallPart)
--- and never asks its own getDuration, so neither the instant cheat nor the mechanics cheat shortens
--- it in single player, as they do ISUninstallVehiclePart's: a lid takes seconds. Gives each install
--- queued and not yet started the time its getDuration gives. Call it in the step that queued it.
function T.shortenQueuedInstalls()
    for _, action in ipairs(ISTimedActionQueue.getTimedActionQueue(T.player()).queue) do
        if action.Type == "ISInstallVehiclePart" and not action.action then
            action.maxTime = action:getDuration()
        end
    end
end

-- In multiplayer a generator taken away while this client's copy of its square holds a different
-- list of objects (a test's own objects come and go fast) keeps its squares powered here: the
-- switch-off names it by its place on the square and misses, and the chunks drop a generator's
-- squares only when they load again (IsoChunk.checkForMissingGenerators). So with the grid off a
-- test starts with no power but what it brings itself.
local function dropStaleGeneratorPower()
    local square = T.player():getCurrentSquare()
    if not square then return end
    local cell, reach = getCell(), math.floor(SandboxVars.GeneratorTileRange / 8) + 2
    local wx, wy = math.floor(square:getX() / 8), math.floor(square:getY() / 8)
    for x = wx - reach, wx + reach do
        for y = wy - reach, wy + reach do
            local chunk = cell:getChunk(x, y)
            if chunk then
                chunk:checkForMissingGenerators()
            end
        end
    end
end

--- The power grid on or off. Off, it also clears power a generator taken away left behind.
function T.setGrid(self, on)
    T.defer(self, PZHarness.Fixtures.setGrid(on))
    Runtime.alsoOnServer(self, "PZHarness.setGrid", { on = on })
    if not on then
        dropStaleGeneratorPower()
    end
end

--- Midnight with the grid off, dark where the character stands; queues a wait for the light to
--- follow the clock.
function T.makeDark(self)
    T.setGrid(self, false)
    T.setTime(self, 0)
    Runtime.waitForLight(false)
end

--- Changes `item`, a client copy such as T.give's, as `changes` says: `condition`, `uses` (the
--- fraction of a full drainable item), `repaired` (vanilla's repair count), `modData` (keys to
--- set); in multiplayer the server's copy too, which it then sends here. Not undone: the runner empties the inventory before the next test.
function T.changeItem(self, item, changes)
    PZHarness.Fixtures.changeItem(item, changes)
    Runtime.alsoOnServer(self, "PZHarness.changeItem", { id = item:getID(), changes = changes })
end

-- Registering tests

-- Why spec's opt-out of single player or multiplayer is malformed, or nil. The reason is required
-- so that every skip says why in the run's summary.
local function optOutProblem(spec)
    if spec.spOnly ~= nil and spec.mpOnly ~= nil then
        return "spOnly and mpOnly both set: the test would run nowhere"
    end
    for _, key in ipairs({ "spOnly", "mpOnly" }) do
        local reason = spec[key]
        if reason ~= nil and (type(reason) ~= "string" or reason == "") then
            return key .. " needs the reason as a string"
        end
    end
    return nil
end

-- The spec's own start of a test, once the light has caught up: the instant cheat, the hour, the
-- sandbox options, the mod's setup, then spec.run unless a fixture is already missing.
local function startSpec(self, spec, hour)
    -- The server makes the actions a multiplayer client sends it, so it decides their length.
    T.defer(self, PZHarness.Fixtures.setInstant(T.player(), spec.instant == true))
    Runtime.alsoOnServer(self, "PZHarness.setInstant", { on = spec.instant == true })
    if hour then
        T.setTime(self, hour)
    end
    for key, value in pairs(spec.sandbox or {}) do
        T.setSandbox(self, key, value)
    end
    if settings().setup then
        settings().setup(self, spec)
    end
    if spec.run and #self.missing == 0 then
        spec.run(self)
    end
end

-- The runner's run of a registered test: a fresh `self`, an undo that gives back the perks of the
-- `perks` setting, then startSpec. A malformed opt-out runs nothing; validate reports it.
local function runEntry(entry, name, spec, problem)
    local self = { name = name, undo = {}, missing = {}, used = {}, server = {}, items = {}, counts = {},
        startedMs = getTimestampMs() }
    entry.state = self
    Runtime.begin(self)
    if problem then
        return
    end
    local p = T.player()
    local perks, ids = {}, {}
    for _, perk in pairs(settings().perks or {}) do
        perks[perk:getId()] = p:getPerkLevel(perk)
        table.insert(ids, perk:getId())
    end
    -- Actions and crafts that give experience level up both copies of the character, so each gets
    -- back the levels it had, at the XP that starts them. A multiplayer client takes the server's:
    -- its own copy can be a perk sync behind (PlayerXpPacket, once a second), and a stale level put
    -- back at every test's end would outlast the syncs that land during the tests.
    T.defer(self, function() PZHarness.Fixtures.setPerkLevels(p, perks) end)
    if #ids > 0 then
        Runtime.alsoOnServer(self, "PZHarness.keepPerkLevels", { perks = ids }, function(reply) perks = reply.levels end)
    end
    -- Read now, not when the test registers: the dev mod may register its settings after its test
    -- files have loaded.
    local hour = spec.hour or settings().hour
    -- The light lags a clock or grid change by some frames, and the previous test may have ended
    -- in the dark.
    if not hour or Runtime.lit() then
        startSpec(self, spec, hour)
    else
        Runtime.waitForLight(true)
        T.step(function() startSpec(self, spec, hour) end)
    end
end

--- Prints a test's verdict: "<tag> PASS <name> (<s> s)", or FAIL with `failures` as its reasons.
--- The harness runner calls it once it has checked the test for leaks; the debug menu's runner
--- gets it from validate.
function T.printVerdict(name, failures, seconds)
    local took = PZHarness.tookSuffix(seconds)
    if #failures > 0 then
        print(PZHarness.run.tag .. " FAIL " .. name .. ": " .. table.concat(failures, "; ") .. took)
    else
        print(PZHarness.run.tag .. " PASS " .. name .. took)
    end
end

-- The runner's validate of a registered test: its failures (a malformed opt-out, the runner's
-- timeout, a cleared action queue, a missing fixture, or spec.validate's), then spec.cleanup and
-- the undos. Leaves the failures in `entry.failures` and the test's wall time, from its run to the
-- end of its undos, in `entry.seconds`, and returns whether the test passed. The verdict is
-- printed here only when the harness runner isn't running the test (PZHarness.runnerOwnsVerdicts),
-- since the runner adds what its leak check finds first.
local function validateEntry(entry, name, spec, problem)
    local self = entry.state or { undo = {}, missing = { "a run before validate" } }
    entry.state = nil
    failures = {}
    if problem then
        table.insert(failures, problem)
    elseif entry.timedOut then
        -- The runner stopped the test (Runner.lua): what validate reads may never have come.
        table.insert(failures, entry.timedOut)
        entry.timedOut = nil
    elseif self.queueCleared then
        -- The steps after the action that emptied the queue never ran, so validate would read
        -- what they never made.
        table.insert(failures, self.queueCleared)
    elseif #self.missing > 0 then
        table.insert(failures, "missing " .. table.concat(self.missing, "; "))
    elseif spec.validate then
        spec.validate(self)
        -- The menu and the crafting windows refuse a craft without saying why.
        if #failures > 0 and self.refusal then
            table.insert(failures, "the game refused the craft: " .. self.refusal)
        end
    end
    if spec.cleanup then
        spec.cleanup(self)
    end
    Runtime.finish(self, failures)
    entry.seconds = self.startedMs and (getTimestampMs() - self.startedMs) / 1000 or 0
    entry.failures = failures
    if not PZHarness.runnerOwnsVerdicts then
        T.printVerdict(name, failures, entry.seconds)
    end
    return #failures == 0
end

--- Registers test `name`. `spec`: run(self), validate(self), cleanup(self), all optional; `hour`;
--- `instant`; `sandbox` (option = value, see T.setSandbox); `spOnly` or `mpOnly`, the reason the
--- test runs only in single player or only in multiplayer; anything else the mod's setup reads.
function T.test(name, spec)
    local problem = optOutProblem(spec)
    TimedActionTests.getTests()[name] = {
        -- The runner reads these to skip the test in the other mode.
        spOnly = not problem and spec.spOnly or nil,
        mpOnly = not problem and spec.mpOnly or nil,
        -- The runner's per-test limit in real seconds, if the test needs more than its default.
        timeoutSeconds = spec.timeoutSeconds,
        run = function(entry) runEntry(entry, name, spec, problem) end,
        validate = function(entry) return validateEntry(entry, name, spec, problem) end,
    }
end

-- Lookups and data

-- In shared/PZHarness/Fixtures.lua, so a dev mod's server handlers have them too.
T.lineUpTrailer = PZHarness.Fixtures.lineUpTrailer
T.objectWithSprite = PZHarness.Fixtures.objectWithSprite
T.countPairs = PZHarness.Fixtures.countPairs

return T
