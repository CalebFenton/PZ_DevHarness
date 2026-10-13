require "Tests/TimedActionsTests"
require "Moveables/ISMoveableSpriteProps"
require "PZHarness/Runner"
require "PZHarness/ServerCalls"
require "PZHarness/Fixtures"

-- The generic half of a mod's test library. A mod's own library inherits from it
-- (setmetatable(ModTest, { __index = PZHarness.Test })) and adds the fixtures that know the mod's
-- objects; its test files register tests with the vanilla timed action test runner through
-- T.test. The runner (the debug menu's Dev > Unit Tests > Timed Actions, or PZHarness/Runner.lua)
-- calls run(), waits until the character's action queue is empty, then calls validate(). Before
-- each test it empties the inventory and the hands, clears worn items and teleports the character
-- back; perks, known recipes, modData, world objects, sandbox options and the clock carry over.
-- Each result goes to console.txt as "<tag> PASS <name>" or "<tag> FAIL <name>: <reasons>".
--
-- Settings, from the `tests` table the dev mod passes to PZHarness.register, all optional:
-- - `hour`: the hour every test runs at unless its spec gives one. A test that runs at an hour
--   first waits for the light, which lags the clock.
-- - `perks`: perks restored after every test, however a test changed them.
-- - `sandbox`: the mod's table in SandboxVars, which T.setSandbox tries before the game's options.
-- - `sandboxChanged()`: called after T.setSandbox sets or restores an option, for state the mod
--   derives from its options.
-- - `setup(self, spec)`: called before every test's spec.run, after its hour and sandbox options;
--   it can push undos with T.defer.
-- - `recipePrefix`: the name prefix of the mod's craftRecipes, for the recipe helpers.
-- - `isFreeSquare(square, indoors)`: where T.squares may put a fixture; by default a walkable
--   square without a vehicle, indoors or outdoors as asked.
-- - `remove(object)`: removes a placed object of the mod the way the mod does, returning true;
--   anything it returns false for T.track removes the vanilla way.
--
-- Rules of the API, so that no test depends on what an earlier one left:
-- - T.test gives every run a fresh `self`, sets the clock to the hour, runs timed actions
--   instantly when `spec.instant` (otherwise at their real duration), and applies `spec.sandbox`.
-- - Each T.set* call, T.defer, T.onTick and every fixture (T.tile, T.bench, T.placeMoveable,
--   T.vehicle, T.track and the mod's) pushes its undo onto the test's restore stack. After
--   validate and `spec.cleanup`, the wrapper unwinds it newest first: it removes what the test
--   placed (running generators switched off first, vehicles permanently) and restores the clock,
--   perks, grid, sandbox options, game speed and the instant cheat.
-- - A fixture that can't be built records what is missing (T.need); the wrapper then fails the
--   test with it and skips spec.validate, so validate never indexes a missing fixture.
-- - A Lua error stops the game in the debug-mode error handler, pcall or not, and the runner never
--   finishes, so tests never throw.
--
-- Single player and multiplayer (run-client.sh --mp) run the same tests. On a multiplayer client
-- the character, its inventory and the world are the client's copies: what only the authority can
-- do (place the mod's objects, run its systems, read its records) goes through T.server, which
-- calls a handler the dev mod registered in its server Lua (server/PZHarness/ServerHandlers.lua)
-- in this game in single player and on the server in multiplayer. A test that can't run in one of
-- the two says so with `spOnly = "<why>"` or `mpOnly = "<why>"`; the runner then skips it in the
-- other and prints "<tag> SKIP <name>: <why>".
PZHarness.Test = {}
local T = PZHarness.Test

-- The longest a test waits for the light to follow the clock or the grid. The lighting catches up
-- at its own pace in real time, so at a high frame rate it takes more ticks.
local LIGHT_FRAMES = 600
-- Squares searched around a fixture's centre, in tiles.
local SEARCH_RADIUS = 30
-- Squares a vehicle is tried on before a test gives up on it.
local VEHICLE_TRIES = 8

local function settings()
    return PZHarness.config.tests
end

function T.player()
    return getSpecificPlayer(0)
end

-- Expectations ---------------------------------------------------------------------------------

-- Unmet expectations of the test being validated.
local failures = {}

function T.expect(condition, message)
    if not condition then
        table.insert(failures, message)
    end
    return condition
end

function T.expectNear(label, actual, expected, tolerance)
    return T.expect(type(actual) == "number" and math.abs(actual - expected) <= (tolerance or 0.0001),
        label .. " is " .. tostring(actual) .. ", expected " .. expected)
end

--- Returns `value`; when it is nil or false, records `what` (a noun phrase: "a free indoor square
--- for a table") as missing, which fails the test without running spec.validate.
function T.need(self, value, what)
    if not value then
        table.insert(self.missing, what)
    end
    return value
end

-- The test being run, from its run to its verdict.
local active

-- Queue ----------------------------------------------------------------------------------------

-- Holds the action queue, so the runner validates only once the world has caught up: until
-- `done()` holds or `total` ticks pass, calling `onTick(n)` every tick. What onTick queues goes
-- right after the wait, in order (vanilla's adding-actions mode, ISQueueActionsAction), and a
-- clear of the queue meanwhile, as luautils.walkAdj makes, drops only that. Once the running test
-- misses a fixture (T.need), every wait ends at once without calling anything, since what comes
-- after would work on the missing fixture.
local Wait = ISBaseTimedAction:derive("PZHarnessWait")

function Wait:isValid()
    return true
end

function Wait:update()
    if active and #active.missing > 0 then
        self:forceComplete()
        return
    end
    self.ticks = self.ticks + 1
    if self.onTick then
        self:beginAddingActions()
        self.onTick(self.ticks)
        self:endAddingActions()
    end
    if self.ticks >= self.total or (self.done and self.done()) then
        self:forceComplete()
    end
end

function Wait:new(character, total, onTick, done)
    local o = ISBaseTimedAction.new(self, character)
    o.total, o.onTick, o.done, o.ticks = total, onTick, done, 0
    o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
    o.maxTime = -1
    return o
end

--- Queues `ticks` ticks of waiting, calling `onTick(n)` every tick.
function T.wait(ticks, onTick)
    ISTimedActionQueue.add(Wait:new(T.player(), ticks, onTick))
end

--- Queues a wait that ends as soon as `condition()` holds, or after `maxFrames` ticks; the
--- following validate checks what it waited for.
function T.waitUntil(condition, maxFrames)
    ISTimedActionQueue.add(Wait:new(T.player(), maxFrames, nil, condition))
end

--- Runs `fn` once the actions queued before it are done. What fn queues (actions, T.server,
--- T.step...) runs right after it, in order, before what was queued after the step.
function T.step(fn)
    ISTimedActionQueue.add(Wait:new(T.player(), 1, function() fn() end))
end

local function lit()
    return not T.player():tooDarkToRead()
end

-- Server ---------------------------------------------------------------------------------------

-- How long the client may take, after the server's answer, to get the items a handler gave and to
-- show them worn and held.
local RECEIVE_MS = 15000

-- Whether the wrapper is unwinding a test's restore stack, so a server undo answered at once
-- (single player) still counts in the test's verdict.
local unwinding = false

-- Takes back on the server what call `id` of handler `name` built. A multiplayer server answers
-- after the test's verdict, so a failure then is reported on its own line and counted by the
-- runner.
local function unwindOnServer(self, name, id)
    PZHarness.ServerCalls.send("unwind", { test = self.name, call = id }, function(answer)
        if not answer.error then
            return
        end
        local failure = "the server's undo of " .. name .. " failed: " .. answer.error
        if unwinding then
            table.insert(failures, failure)
        else
            print(PZHarness.run.tag .. " FAIL " .. self.name .. ": " .. failure)
            PZHarness.ServerCalls.lateFailures = PZHarness.ServerCalls.lateFailures + 1
        end
    end)
end

-- The queued steps after the current one, which a failed server call leaves nothing to work on.
local function dropQueuedSteps()
    local queue = ISTimedActionQueue.getTimedActionQueue(T.player()).queue
    for i = #queue, 2, -1 do
        table.remove(queue, i)
    end
    -- A step adding actions (Wait:update) adds the next one right after itself again.
    if queue[1] and queue[1]._numAddedActions then
        queue[1]._numAddedActions = 0
    end
end

-- The client's copies of the items in `given` (see PZHarness.giveItem), in order, or nil while one
-- hasn't arrived.
local function clientCopies(given)
    local inventory = T.player():getInventory()
    local items = {}
    for _, entry in ipairs(given) do
        local item = inventory:getItemById(entry.id)
        if not item then
            return nil
        end
        table.insert(items, item)
    end
    return items
end

local function inPrimary(entry)
    return entry.equip == "primary" or entry.equip == "both"
end

local function inSecondary(entry)
    return entry.equip == "secondary" or entry.equip == "both"
end

local function needsDressing(given)
    for _, entry in ipairs(given) do
        if entry.worn or entry.equip then
            return true
        end
    end
    return false
end

-- Whether the client shows `items` worn and held as `given` says.
local function dressedAsGiven(items, given)
    local p = T.player()
    for i, entry in ipairs(given) do
        local item = items[i]
        if (entry.worn and not p:getWornItems():contains(item))
            or (inPrimary(entry) and p:getPrimaryHandItem() ~= item)
            or (inSecondary(entry) and p:getSecondaryHandItem() ~= item) then
            return false
        end
    end
    return true
end

-- Sends the call of the server handler `name` at once and handles its answer: the server's undo,
-- a failure (as T.need does, dropping the steps queued after it), `onReply(reply)`, and the items
-- the reply lists as `given` (PZHarness.giveItem): once the client has them, worn and held as they
-- should be (the server dresses the character only then, "PZHarness.dress"), their client copies
-- land in self.items[itemsKey]. Returns the condition a queued wait polls until all of it is done.
local function call(self, name, args, itemsKey, onReply)
    local phase, given, sinceMs = "asking", nil, nil
    local function fail(what)
        T.need(self, nil, what)
        dropQueuedSteps()
        phase = "done"
    end
    local function ask(handler, handlerArgs, onAnswer)
        PZHarness.ServerCalls.send("call", { name = handler, test = self.name, args = handlerArgs }, function(answer)
            if answer.undo then
                local function undo() unwindOnServer(self, handler, answer.id) end
                -- An answer can come after the verdict once a missing fixture ended the test's waits.
                if self.unwound then undo() else T.defer(self, undo) end
            end
            if answer.error or answer.missing then
                fail(answer.missing or "the server's " .. handler .. ", which failed: " .. answer.error)
                return
            end
            onAnswer(answer.reply or {})
        end)
    end
    ask(name, args or {}, function(reply)
        if onReply then
            onReply(reply)
        end
        given, sinceMs = reply.given, getTimestampMs()
        phase = given and "receiving" or "done"
    end)
    return function()
        if phase == "receiving" or phase == "dressing" then
            local items = clientCopies(given)
            if items and phase == "receiving" and needsDressing(given) then
                phase = "asking"
                ask("PZHarness.dress", { given = given }, function()
                    phase, sinceMs = "dressing", getTimestampMs()
                end)
            elseif items and dressedAsGiven(items, given) then
                self.items[itemsKey] = items
                phase = "done"
            elseif getTimestampMs() - sinceMs > RECEIVE_MS then
                fail("this client's copies of what the server's " .. name .. " gave")
            end
        end
        return phase == "done"
    end
end

-- Queues a call that goes out once the actions queued before it are done, and a wait for all of
-- it. `args` may be a function of `self`.
local function queueCall(self, name, args, itemsKey, onReply)
    local poll
    T.step(function()
        poll = call(self, name, type(args) == "function" and args(self) or args or {}, itemsKey, onReply)
    end)
    -- The answer, or the error ServerCalls gives a lost one, always comes, so no frame cap. A step
    -- skipped after a missing fixture leaves no poll.
    T.waitUntil(function() return not poll or poll() end, math.huge)
end

--- Queues a call of the server handler `name` (see server/PZHarness/ServerHandlers.lua) and a
--- wait for its answer, which lands in `self.server[name]`. `args` is a table of plain values
--- (strings, numbers, booleans and tables of them), or a function of `self` returning one, called
--- when the call goes out, so it can use an earlier answer. In single player the handler runs in
--- this game and answers at once; in multiplayer it runs on the server. What it deferred is undone
--- on its side when the test ends, in order with the test's own undos. A handler that fails, or
--- answers that something is missing, fails the test as T.need does and drops the steps queued
--- after the call. A handler that gave the character items lists them in its reply as `given`
--- (PZHarness.giveItem); the wait then lasts until this client has them, worn and held as asked,
--- and puts this client's copies in `self.items[name]`.
function T.server(self, name, args)
    queueCall(self, name, args, name, function(reply) self.server[name] = reply end)
end

--- Queues calls of the server handler `name`, one at a time, until `done(reply)` holds or `maxMs`
--- of real time (15 seconds unless given) pass, for server state that changes later, such as what
--- an action's complete() does after the client's perform(). The last reply lands in
--- `self.server[name]`; running out of time just ends the wait, so validate checks what it waited
--- for. `args` as for T.server; a failed call fails the test as T.server's does.
function T.serverUntil(self, name, args, done, maxMs)
    local poll, sinceMs
    T.waitUntil(function()
        sinceMs = sinceMs or getTimestampMs()
        if poll then
            if not poll() then
                return false
            end
            if done(self.server[name]) or getTimestampMs() - sinceMs > (maxMs or RECEIVE_MS) then
                return true
            end
        end
        poll = call(self, name, type(args) == "function" and args(self) or args or {}, name, function(reply)
            self.server[name] = reply
        end)
        return false
    end, math.huge)
end

--- Gives the character `items` the way the server does: each a table { type = full type, count,
--- uses (fraction of a full drainable item), condition, modData (keys to set), worn = true,
--- equip = "primary", "secondary" or "both" }. Queued like T.server; this client's copies land in
--- `self.items[name]`, `count` of each in the order given. In multiplayer the server makes them,
--- sends them here and then puts them on and in hand, so actions that run on the server find them.
--- The runner empties the inventory before the next test.
function T.give(self, name, items)
    queueCall(self, "PZHarness.give", { items = items }, name)
end

--- Queues a count of each of `types` in the inventory of the server's copy of the character, bags
--- included, into `self.counts[name][fullType]`. With `opts.dropped`, items dropped on the squares
--- around the character count too and go away, as a craft drops what doesn't fit.
function T.count(self, name, types, opts)
    queueCall(self, "PZHarness.count", { types = types, dropped = opts and opts.dropped or nil }, nil, function(reply)
        self.counts[name] = reply.counts
    end)
end

-- The server's half of a two-sided fixture (server/PZHarness/ServerFixtures.lua), on a
-- multiplayer client only: sent at once, so it reaches the server before any later T.server call,
-- with a wait for its answer queued, so the actions queued after the fixture start only once the
-- server has made the change. Single player has made it already, in its one copy.
local function alsoOnServer(self, name, args, onReply)
    if isClient() then
        T.waitUntil(call(self, name, args, nil, onReply), math.huge)
    end
end

-- The same for two-sided helpers that take no test, which scenarios call too: a failure prints a
-- FAIL line of its own. `ready(reply)`, if given, holds once this client has what the server did.
local function alsoOnServerOutsideTest(name, args, ready)
    if not isClient() then
        return
    end
    local reply, sinceMs
    PZHarness.ServerCalls.callOutsideTest(name, args, function(answer)
        reply, sinceMs = answer, getTimestampMs()
    end)
    T.waitUntil(function()
        if not reply then
            return not PZHarness.ServerCalls.busy()
        end
        if not ready or ready(reply) then
            return true
        end
        if getTimestampMs() - sinceMs > RECEIVE_MS then
            print(PZHarness.run.tag .. " FAIL " .. name .. ": this client never got what the server did")
            PZHarness.ServerCalls.lateFailures = PZHarness.ServerCalls.lateFailures + 1
            return true
        end
        return false
    end, math.huge)
end

-- Restore stack --------------------------------------------------------------------------------

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
-- client the server's copy too (see alsoOnServer), which the server undoes when the test ends.

function T.setTime(self, hour)
    T.defer(self, PZHarness.Fixtures.setTime(hour))
    alsoOnServer(self, "PZHarness.setTime", { hour = hour }, function()
        -- A clock sync the server sent before it changed the time may have come in since.
        getGameTime():setTimeOfDay(hour)
    end)
end

function T.setPerk(self, perk, level)
    T.defer(self, PZHarness.Fixtures.setPerk(T.player(), perk, level))
    alsoOnServer(self, "PZHarness.setPerk", { perk = perk:getId(), level = level })
end

local function sandboxChanged()
    if settings().sandboxChanged then
        settings().sandboxChanged()
    end
end

--- Sets a sandbox option of the mod (SandboxVars[settings.sandbox]) or, failing that, of the
--- game. An option in neither is recorded as missing rather than created. The server calls its
--- own `PZHarness.serverSettings.sandboxChanged` (server/PZHarness/ServerFixtures.lua).
function T.setSandbox(self, key, value)
    local options = PZHarness.Fixtures.sandboxOptions(settings().sandbox, key)
    if not T.need(self, options, "the sandbox option " .. key) then return end
    T.defer(self, PZHarness.Fixtures.setSandbox(options, key, value, sandboxChanged))
    alsoOnServer(self, "PZHarness.setSandbox", { table = settings().sandbox, key = key, value = value })
end

--- The game runs `multiplier` times as fast: the clock and every timed action alike. The game drops
--- back to 1 when the character moves without a path or a zombie comes close.
function T.setMultiplier(self, multiplier)
    T.defer(self, PZHarness.Fixtures.setMultiplier(multiplier))
    alsoOnServer(self, "PZHarness.setMultiplier", { multiplier = multiplier })
end

--- The power grid on or off.
function T.setGrid(self, on)
    T.defer(self, PZHarness.Fixtures.setGrid(on))
    alsoOnServer(self, "PZHarness.setGrid", { on = on })
end

--- Midnight with the grid off, dark where the character stands; queues a wait for the light to
--- follow the clock.
function T.makeDark(self)
    T.setGrid(self, false)
    T.setTime(self, 0)
    T.waitUntil(function() return not lit() end, LIGHT_FRAMES)
end

--- Changes `item`, a client copy such as T.give's, as `changes` says: `condition`, `uses` (the
--- fraction of a full drainable item), `modData` (keys to set); in multiplayer the server's copy
--- too, which it then sends here. Not undone: the runner empties the inventory before the next test.
function T.changeItem(self, item, changes)
    PZHarness.Fixtures.changeItem(item, changes)
    alsoOnServer(self, "PZHarness.changeItem", { id = item:getID(), changes = changes })
end

-- Registering tests ----------------------------------------------------------------------------

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

--- Registers test `name`. `spec`: run(self), validate(self), cleanup(self), all optional; `hour`;
--- `instant`; `sandbox` (option = value, see T.setSandbox); `spOnly` or `mpOnly`, the reason the
--- test runs only in single player or only in multiplayer; anything else the mod's setup reads.
function T.test(name, spec)
    local problem = optOutProblem(spec)
    local function start(self, hour)
        -- The server makes the actions a multiplayer client sends it, so it decides their length.
        T.defer(self, PZHarness.Fixtures.setInstant(T.player(), spec.instant == true))
        alsoOnServer(self, "PZHarness.setInstant", { on = spec.instant == true })
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
    TimedActionTests.getTests()[name] = {
        -- The runner reads these to skip the test in the other mode.
        spOnly = not problem and spec.spOnly or nil,
        mpOnly = not problem and spec.mpOnly or nil,
        run = function(entry)
            local self = { name = name, undo = {}, missing = {}, used = {}, server = {}, items = {}, counts = {} }
            entry.state = self
            active = self
            if problem then
                return
            end
            local p = T.player()
            local perks = {}
            for _, perk in pairs(settings().perks or {}) do
                perks[perk:getId()] = p:getPerkLevel(perk)
            end
            -- Actions and crafts that give experience level up the server's copy as well, so it
            -- gets back these levels too.
            T.defer(self, function()
                PZHarness.Fixtures.setPerkLevels(p, perks)
                if isClient() then
                    PZHarness.ServerCalls.callOutsideTest("PZHarness.setPerkLevels", { levels = perks })
                end
            end)
            -- Read now, not when the test registers: the dev mod may register its settings after
            -- its test files have loaded.
            local hour = spec.hour or settings().hour
            -- The light lags a clock or grid change by some frames, and the previous test may
            -- have ended in the dark.
            if not hour or lit() then
                start(self, hour)
            else
                T.waitUntil(lit, LIGHT_FRAMES)
                T.step(function() start(self, hour) end)
            end
        end,
        validate = function(entry)
            local self = entry.state or { undo = {}, missing = { "a run before validate" } }
            entry.state = nil
            failures = {}
            if problem then
                table.insert(failures, problem)
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
            unwinding = true
            for i = #self.undo, 1, -1 do
                self.undo[i]()
            end
            unwinding = false
            self.unwound = true
            active = nil
            if #failures > 0 then
                print(PZHarness.run.tag .. " FAIL " .. name .. ": " .. table.concat(failures, "; "))
                return false
            end
            print(PZHarness.run.tag .. " PASS " .. name)
            return true
        end,
    }
end

-- Squares --------------------------------------------------------------------------------------

local function squareOf(near)
    if not near then
        return T.player():getCurrentSquare()
    end
    return instanceof(near, "IsoGridSquare") and near or near:getSquare()
end

local function isFreeSquare(square, indoors)
    if settings().isFreeSquare then
        return settings().isFreeSquare(square, indoors)
    end
    return square:isFree(false) and square:getVehicleContainer() == nil and square:isOutside() ~= indoors
end

-- Up to `count` free squares; see T.squares.
local function freeSquares(self, count, opts)
    local center = squareOf(opts.near)
    local found = {}
    if not center then return found end
    for radius = opts.minDistance or 1, SEARCH_RADIUS do
        for dx = -radius, radius do
            for dy = -radius, radius do
                local square = math.max(math.abs(dx), math.abs(dy)) == radius
                    and getSquare(center:getX() + dx, center:getY() + dy, center:getZ())
                if #found < count and square and not self.used[square]
                    and isFreeSquare(square, opts.indoors == true)
                    and (not opts.bare or square:getObjects():size() == 1) then
                    self.used[square] = true
                    table.insert(found, square)
                end
            end
        end
    end
    return found
end

--- `count` free squares (the `isFreeSquare` setting) around `opts.near` (a square or object; the
--- character's square by default), nearest first and at least `opts.minDistance` tiles away:
--- indoors when `opts.indoors`, else outdoors; holding only their floor when `opts.bare`. Each
--- square goes to one fixture per test. Nil unless all are found.
function T.squares(self, count, opts)
    local found = freeSquares(self, count, opts or {})
    return #found == count and found or nil
end

-- Fixtures -------------------------------------------------------------------------------------

--- Removes `thing` (an IsoObject or a vehicle) when the test ends, the way the game does, so the
--- mods' removal handlers run. Returns `thing`.
function T.track(self, thing)
    T.defer(self, function()
        if instanceof(thing, "BaseVehicle") then
            thing:permanentlyRemove()
        elseif thing:getObjectIndex() ~= -1 then
            if settings().remove and settings().remove(thing) then
                return
            end
            -- Squares stay powered by a running generator that leaves them.
            if instanceof(thing, "IsoGenerator") and thing:isActivated() then
                thing:setActivated(false)
            end
            thing:getSquare():transmitRemoveItemFromSquare(thing)
        end
    end)
    return thing
end

--- A tile object of `sprite` on `square`, with `modData`.
function T.tile(self, square, sprite, modData)
    local object = IsoObject.new(square, sprite, "PZHarness")
    for key, value in pairs(modData or {}) do
        object:getModData()[key] = value
    end
    square:AddTileObject(object)
    return T.track(self, object)
end

--- Places a new `itemType` on `square` the way the moveables cursor does, with `modData` on the
--- item first. Returns the placed object.
function T.placeMoveable(self, square, itemType, sprite, modData)
    local item = instanceItem(itemType)
    for key, value in pairs(modData or {}) do
        item:getModData()[key] = value
    end
    T.player():getInventory():AddItem(item)
    ISMoveableSpriteProps.new(sprite):placeMoveable(T.player(), square, item:getWorldSprite(), true)
    local object = T.objectWithSprite(square, sprite)
    return T.need(self, object and T.track(self, object), "a placed " .. itemType)
end

-- A free square next to the character, with no wall in between, for a bench of `entity`; nil, and
-- missing, without one.
local function benchSquare(self, entity)
    local here = T.player():getSquare()
    for _, direction in ipairs({ IsoDirections.S, IsoDirections.E, IsoDirections.N, IsoDirections.W }) do
        local next = here:getAdjacentSquare(direction)
        if next and not self.used[next] and next:isFree(false) and not here:isBlockedTo(next) then
            self.used[next] = true
            return next
        end
    end
    return T.need(self, nil, "a free square next to the character for a " .. entity)
end

--- A workstation of the entity script `entity` (such as "Base.Kiln_Small"), drawn as `sprite`,
--- on a free square next to the character, who is using it as its crafting window makes them.
--- Returns the object. On a multiplayer client it exists here only: use T.placeBench.
function T.bench(self, entity, sprite)
    local script = T.need(self, getScriptManager():getGameEntityScript(entity), "the entity script " .. entity)
    local square = script and benchSquare(self, entity)
    if not square then
        return nil
    end
    local bench = IsoObject.new(square, sprite, entity)
    GameEntityFactory.CreateIsoObjectEntity(bench, script, true)
    square:AddTileObject(bench)
    T.track(self, bench)
    bench:setUsingPlayer(T.player())
    return T.need(self, bench:getComponent(ComponentType.CraftBench) and bench, "a craft bench in " .. entity)
end

-- Sends the call of handler `name`, which places something, and queues a wait until `find()`
-- finds this client's copy, into handle[key] ("object" unless given); `onReply(reply)` gets the
-- answer first. Single player finds it at once.
local function placeOnServer(self, handle, name, args, find, what, key, onReply)
    key = key or "object"
    local poll = call(self, name, args, nil, onReply)
    local sinceMs
    local function ready()
        handle[key] = find()
        return handle[key] ~= nil
    end
    if poll() then
        ready()
    end
    T.waitUntil(function()
        if not poll() then
            return false
        end
        if #self.missing > 0 or ready() then
            return true
        end
        sinceMs = sinceMs or getTimestampMs()
        if getTimestampMs() - sinceMs > RECEIVE_MS then
            T.need(self, nil, "this client's copy of " .. what)
            return true
        end
        return false
    end, math.huge)
    return handle
end

--- A tile object of `sprite` on `square`, with `modData`, placed the way the authority does: on
--- the server in multiplayer, which sends it to the clients. Removed when the test ends, by the
--- dev mod's `PZHarness.serverSettings.remove` if it takes it (server/PZHarness/ServerFixtures.lua),
--- else the vanilla way. Returns a handle { x, y, z, square } at once; handle.object is this
--- client's copy, there at once in single player and after a queued wait in multiplayer.
function T.placeTile(self, square, sprite, modData)
    local handle = { x = square:getX(), y = square:getY(), z = square:getZ(), square = square }
    local args = { x = handle.x, y = handle.y, z = handle.z, sprite = sprite, modData = modData }
    return placeOnServer(self, handle, "PZHarness.tile", args, function()
        return T.objectWithSprite(getSquare(handle.x, handle.y, handle.z), sprite)
    end, "a " .. sprite)
end

--- T.bench placed the way the authority does, as T.placeTile places a tile: returns a handle
--- { x, y, z, square } at once, or nil without a free square, and handle.object is this client's
--- copy of the bench once it has one.
function T.placeBench(self, entity, sprite)
    local square = benchSquare(self, entity)
    if not square then
        return nil
    end
    local handle = { x = square:getX(), y = square:getY(), z = square:getZ(), square = square }
    local args = { x = handle.x, y = handle.y, z = handle.z, entity = entity, sprite = sprite }
    return placeOnServer(self, handle, "PZHarness.bench", args, function()
        local bench = T.objectWithSprite(getSquare(handle.x, handle.y, handle.z), sprite)
        return bench and bench:getComponent(ComponentType.CraftBench) and bench
    end, "a " .. entity)
end

-- The squares T.vehicle tries, nearest first: `opts.square`, else open ground near `opts.near`
-- (the character by default), far enough that the vehicle doesn't land on the character.
local function vehicleSquares(self, opts)
    return opts.square and { opts.square }
        or freeSquares(self, VEHICLE_TRIES, { near = opts.near, minDistance = 4, bare = true })
end

--- A vehicle of `script` facing north on `opts.square`, else on open ground near `opts.near`
--- (the character by default). Returns the vehicle. On a multiplayer client it exists here only:
--- use T.placeVehicle.
function T.vehicle(self, script, opts)
    for _, square in ipairs(vehicleSquares(self, opts or {})) do
        -- addVehicleDebug returns a vehicle even where it leaves it out of the world, as it does
        -- where it would hit another vehicle; only a vehicle in the world gets an id
        -- (BaseVehicle.createPhysics).
        local vehicle = addVehicleDebug(script, IsoDirections.N, nil, square)
        if vehicle and vehicle:getId() ~= -1 then
            return T.track(self, vehicle)
        end
    end
    T.need(self, nil, "open ground for a " .. script)
    return nil
end

--- T.vehicle placed the way the authority does: on the server in multiplayer, which sends it to
--- the clients nearby; removed when the test ends. `opts`: `square` or `near` as for T.vehicle,
--- `facing` ("N" unless given), `args` (plain values for the dev mod's
--- PZHarness.serverSettings.spawnVehicle, which makes the vehicle if it returns one). Returns a
--- handle at once. Once the server has answered, handle.id (shared by the server and its clients;
--- PZHarness.Fixtures.vehicleById finds it on either side), x, y, z and square say where it went,
--- and after a queued wait handle.vehicle is this client's copy.
function T.placeVehicle(self, script, opts)
    opts = opts or {}
    local squares = {}
    for _, square in ipairs(vehicleSquares(self, opts)) do
        table.insert(squares, { x = square:getX(), y = square:getY(), z = square:getZ() })
    end
    local handle = {}
    local args = { script = script, squares = squares, facing = opts.facing, args = opts.args }
    return placeOnServer(self, handle, "PZHarness.vehicle", args, function()
        return PZHarness.Fixtures.vehicleById(handle.id, handle)
    end, "a " .. script, "vehicle", function(reply)
        handle.id, handle.x, handle.y, handle.z = reply.id, reply.x, reply.y, reply.z
        handle.square = getSquare(reply.x, reply.y, reply.z)
    end)
end

-- Lookups and data -----------------------------------------------------------------------------

-- In shared/PZHarness/Fixtures.lua, so a dev mod's server handlers have them too.
T.lineUpTrailer = PZHarness.Fixtures.lineUpTrailer
T.objectWithSprite = PZHarness.Fixtures.objectWithSprite
T.countPairs = PZHarness.Fixtures.countPairs

-- Recipes --------------------------------------------------------------------------------------

--- Every craftRecipe whose name starts with `prefix` (the `recipePrefix` setting by default).
function T.recipeNames(prefix)
    prefix = prefix or settings().recipePrefix or ""
    local names = {}
    local recipes = getScriptManager():getAllCraftRecipes()
    for i = 0, recipes:size() - 1 do
        local name = recipes:get(i):getName()
        if PZHarness.startsWith(name, prefix) then
            table.insert(names, name)
        end
    end
    return names
end

--- Teaches `player` every recipe whose name starts with `prefix` (the `recipePrefix` setting by
--- default); in multiplayer the server's copy too. Not undone. Callable outside a test, as from a
--- scenario's onStart; in multiplayer it queues a wait for the server, so a craft queued after it
--- starts once the server knows the recipes.
function T.learnRecipes(player, prefix)
    local names = T.recipeNames(prefix)
    PZHarness.Fixtures.learnRecipes(player, names)
    alsoOnServerOutsideTest("PZHarness.learnRecipes", { names = names })
end

--- The opposite of T.learnRecipes. The server sends a client the recipes it learns but never the
--- ones it forgets (SyncPlayerFieldsPacket), so both sides forget them.
function T.forgetRecipes(player, prefix)
    local names = T.recipeNames(prefix)
    PZHarness.Fixtures.forgetRecipes(player, names)
    alsoOnServerOutsideTest("PZHarness.forgetRecipes", { names = names })
end

local function pickInputItem(possible, prefer)
    for _, wanted in ipairs(prefer or {}) do
        for j = 0, possible:size() - 1 do
            if possible:get(j):getFullName() == wanted then
                return possible:get(j)
            end
        end
    end
    for j = 0, possible:size() - 1 do
        if possible:get(j):getFullName() ~= "Base.Moveable" then
            return possible:get(j)
        end
    end
    return possible:size() > 0 and possible:get(0) or nil
end

--- What one craft of `recipe` takes, tools included, as T.give items: each input gets the first
--- of its possible items listed in `prefer`, else its first possible item other than a generic
--- Base.Moveable; a drainable input that counts uses gets one full item. Also returns the inputs
--- that had no possible item at all.
function T.recipeInputs(recipe, prefer)
    local items, unmatched = {}, {}
    local inputs = recipe:getInputs()
    for i = 0, inputs:size() - 1 do
        local input = inputs:get(i)
        local item = pickInputItem(input:getPossibleInputItems(), prefer)
        if item then
            local count = input:getIntAmount()
            if item:isItemType(ItemType.DRAINABLE) and not input:isItemCount() then
                count = 1
            end
            table.insert(items, { type = item:getFullName(), count = count })
        else
            table.insert(unmatched, input:getOriginalLine())
        end
    end
    return items, unmatched
end

--- Adds T.recipeInputs to this game's inventory at once; returns the inputs that had no possible
--- item. A multiplayer server doesn't get them: give them with T.give instead.
function T.addRecipeInputs(player, recipe, prefer)
    local items, unmatched = T.recipeInputs(recipe, prefer)
    for _, item in ipairs(items) do
        player:getInventory():AddItems(item.type, item.count)
    end
    return unmatched
end

--- AnySurfaceCraft recipes need a table the character can walk to. Puts one on a free square next
--- to the character, with no wall in between, unless one is there already
--- (PZHarness.Fixtures.placeWorkTable). Not undone: scenarios call it too, and a table left
--- standing harms no later test. In multiplayer the server places it, since one placed here would
--- exist on this client only, and a queued wait lasts until this client has it.
function T.placeWorkTable(player)
    if not isClient() then
        assert(PZHarness.Fixtures.placeWorkTable(player), "PZHarness: no free square next to the character for a table")
        return
    end
    alsoOnServerOutsideTest("PZHarness.workTable", {}, function(at)
        local square = getSquare(at.x, at.y, at.z)
        return T.objectWithSprite(square, PZHarness.Fixtures.WORK_TABLE_SPRITE) ~= nil
    end)
end

-- Crafting -------------------------------------------------------------------------------------

-- The crafting logic the game starts `recipe` from the item `from` with: the right-click menu's,
-- with a table in reach as the surface, or with `bench` (from T.bench) the bench window's.
local function craftLogic(recipe, from, bench)
    local p = T.player()
    local logic
    if bench then
        logic = HandcraftLogic.new(p, bench:getComponent(ComponentType.CraftBench), bench)
    else
        logic = HandcraftLogic.new(p, nil, nil)
        logic:setIsoObject(logic:findCraftSurface(p, 2))
    end
    logic:setContainers(ISInventoryPaneContextMenu.getContainers(p))
    logic:setRecipeFromContextClick(recipe, from)
    return logic
end

-- Why the game would refuse to start this craft, or nil if it would start it. The menu and the
-- crafting windows refuse without saying why.
function T.craftRefusal(recipe, from, bench)
    local p = T.player()
    local logic = craftLogic(recipe, from, bench)
    if logic:canPerformCurrentRecipe() then
        return nil
    elseif not p:isRecipeActuallyKnown(recipe) then
        return "recipe not known"
    elseif not recipe:characterHasRequiredSkills(p) then
        return "skills too low"
    elseif recipe:isAnySurfaceCraft() and not logic:isCharacterInRangeOfWorkbench() then
        return "no table in reach"
    elseif p:tooDarkToRead() then
        return "too dark"
    end
    local missing = {}
    local inputs = recipe:getInputs()
    for i = 0, inputs:size() - 1 do
        local data = logic:getRecipeData():getDataForInputScript(inputs:get(i))
        if data and not data:isInputItemsSatisfied() then
            table.insert(missing, inputs:get(i):getOriginalLine())
        end
    end
    return "missing " .. table.concat(missing, "; ")
end

--- Starts crafting `recipe` from the item `from` the way the right-click menu does or, with
--- `bench` (from T.bench), the way the bench's crafting window does. Adds why the game refused
--- to `self.refusal`, which the test's failures then end with.
function T.startCraft(self, recipe, from, bench)
    local refusal = T.craftRefusal(recipe, from, bench)
    if refusal then
        self.refusal = (self.refusal and self.refusal .. "; " or "") .. recipe:getName() .. ": " .. refusal
    end
    if bench then
        ISEntityUI.HandcraftStart(T.player(), craftLogic(recipe, from, bench), false, true)
    else
        ISInventoryPaneContextMenu.OnNewCraft(from, recipe, T.player():getPlayerNum(), false)
    end
end

--- Registers a test that crafts `spec.recipe` from the first `spec.from` item the way the
--- right-click menu does or, with `spec.bench` ({ entity script, sprite }, see T.bench), at that
--- workstation the way its crafting window does; instantly unless `spec.instant` is false. The
--- character knows every recipe of the mod, has at least the levels the recipe requires, stands
--- by a table, and carries exactly the inputs of one craft (T.recipeInputs with `spec.prefer`,
--- given with T.give, so this client's copies are in `self.items.inputs`) and whatever
--- `spec.setup(self)` adds; setup runs once the inputs are there, and the craft starts after the
--- waits it queued. validate() expects the counts in `spec.counts` in the inventory of the
--- server's copy of the character or dropped at its feet (T.count, into `self.counts.craft`),
--- then runs `spec.validate(self)`. A failing test also reports why the game refused the craft.
function T.craftTest(name, spec)
    local counted = {}
    for fullType in pairs(spec.counts or {}) do
        table.insert(counted, fullType)
    end
    T.test(name, {
        sandbox = spec.sandbox,
        hour = spec.hour,
        instant = spec.instant ~= false,
        spOnly = spec.spOnly,
        mpOnly = spec.mpOnly,
        run = function(self)
            local p = T.player()
            local recipe = T.need(self, getScriptManager():getCraftRecipe(spec.recipe), "the recipe " .. spec.recipe)
            if not recipe then return end
            T.learnRecipes(p)
            T.placeWorkTable(p)
            local bench = spec.bench and T.placeBench(self, spec.bench[1], spec.bench[2])
            if spec.bench and not bench then return end
            for i = 0, recipe:getRequiredSkillCount() - 1 do
                local skill = recipe:getRequiredSkill(i)
                if p:getPerkLevel(skill:getPerk()) < skill:getLevel() then
                    T.setPerk(self, skill:getPerk(), skill:getLevel())
                end
            end
            local inputs, unmatched = T.recipeInputs(recipe, spec.prefer)
            if not T.need(self, #unmatched == 0, "an item for " .. table.concat(unmatched, "; ")) then return end
            T.give(self, "inputs", inputs)
            T.step(function()
                if spec.setup then
                    spec.setup(self)
                end
                T.step(function()
                    local from = T.need(self, p:getInventory():getFirstTypeRecurse(spec.from), "a " .. spec.from .. " to craft from")
                    if not from then return end
                    T.startCraft(self, recipe, from, bench and bench.object)
                    -- Queued after the craft's actions, which T.startCraft has just queued.
                    T.count(self, "craft", counted, { dropped = true })
                end)
            end)
        end,
        validate = function(self)
            local counts = self.counts.craft or {}
            for fullType, count in pairs(spec.counts or {}) do
                local actual = counts[fullType]
                T.expect(actual == count, tostring(actual) .. " " .. fullType .. ", expected " .. count)
            end
            if spec.validate then
                spec.validate(self)
            end
        end,
    })
end

return T
