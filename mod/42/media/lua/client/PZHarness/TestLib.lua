require "Tests/TimedActionsTests"
require "Moveables/ISMoveableSpriteProps"
require "Moveables/ISMoveablesAction"
require "PZHarness/Runner"
require "PZHarness/ServerCalls"
require "PZHarness/Fixtures"
require "PZHarness/Checks"

-- The generic half of a mod's test library. A mod's own library inherits from it
-- (setmetatable(ModTest, { __index = PZHarness.Test })) and adds the fixtures that know the mod's
-- objects; its test files register tests with the vanilla timed action test runner through
-- T.test. The runner (the debug menu's Dev > Unit Tests > Timed Actions, or PZHarness/Runner.lua)
-- calls run(), waits until the character's action queue is empty, then calls validate(). Before
-- each test it empties the inventory and the hands, clears worn items and teleports the character
-- back; perks, known recipes, modData, world objects, sandbox options and the clock carry over.
-- Each result goes to console.txt as "<tag> PASS <name>" or "<tag> FAIL <name>: <reasons>".
--
-- Settings and hooks come from the dev mod's PZHarness.registerTests, in its shared Lua, which
-- both sides read; shared/PZHarness/Fixtures.lua lists them.
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

-- The longest a test waits for the light to follow the clock or the grid, in real milliseconds. The
-- lighting catches up at its own pace in real time, whatever the frame rate, and on a multiplayer
-- client only after the server's clock has come back to it.
local LIGHT_MS = 10000
-- Squares searched around a fixture's centre, in tiles. The runner's leak check looks a little
-- further by default.
local SEARCH_RADIUS = 30
T.SEARCH_RADIUS = SEARCH_RADIUS
-- Squares a vehicle is tried on before a test gives up on it.
local VEHICLE_TRIES = 8

local function settings()
    return PZHarness.testSettings
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
    local ok, message = PZHarness.Checks.near(label, actual, expected, tolerance)
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

-- The test being run, from its run to its verdict.
local active
-- Whether T.batch is running its fn, so what it queues may be crossed (see sendAhead).
local batching = false

-- Queue ----------------------------------------------------------------------------------------

-- Holds the action queue, so the runner validates only once the world has caught up: until
-- `done()` holds or `total` ticks pass, calling `onTick(n)` every tick. What onTick queues goes
-- right after the wait, in order (vanilla's adding-actions mode, ISQueueActionsAction), and a
-- clear of the queue meanwhile, as luautils.walkAdj makes, drops only that. Once the running test
-- misses a fixture (T.need), every wait ends at once without calling anything, since what comes
-- after would work on the missing fixture.
local Wait = ISBaseTimedAction:derive("PZHarnessWait")

-- In multiplayer, sends the server calls queued behind the current action ahead of their turn,
-- each as soon as everything queued before it is `crossable`: a call that is out and whose answer
-- changes nothing on the server when it comes (the setters', T.give's unless it dresses the
-- character, T.count's), or what T.batch queued. The server takes requests in the order they were
-- sent, so it sees the same calls in the same order, only without a round trip between them; each
-- answer still reaches the test in its turn (see call). A call whose args are a function goes out
-- only in its turn, and so does everything queued after it.
local function sendAhead(queue)
    for i, action in ipairs(queue) do
        if i > 1 and action.ahead then
            action.ahead(i)
        end
        if not action.crossable then
            return
        end
    end
end

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
    if isClient() and active and self.test == active then
        sendAhead(ISTimedActionQueue.getTimedActionQueue(self.character).queue)
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
    o.test = active
    o.crossable = false
    return o
end

-- Queues a Wait and returns it.
local function queueWait(total, onTick, done, what)
    local wait = Wait:new(T.player(), total, onTick, done)
    wait.what = what
    ISTimedActionQueue.add(wait)
    return wait
end

-- A test's own wait that goes without finishing means a timed action emptied the queue: one that
-- turned invalid or was refused stops (ISBaseTimedAction.stop), and that cancels everything queued
-- after it, so the test's later steps would silently never run and validate would read what they
-- never made. The test then fails with the action that was running. A step's own clear of what
-- it added (adding-actions mode, as luautils.walkAdj does) drops only that, on purpose.
local function noteLostWait(wait)
    local test = wait.test
    if not test or test ~= active or test.queueCleared then
        return
    end
    local queue = ISTimedActionQueue.getTimedActionQueue(wait.character)
    if queue:isCurrentActionAddingOtherActions() then
        return
    end
    test.queueCleared = "the action queue was cleared while " .. T.describeAction(queue.queue[1] or wait)
        .. " was running; a refused or invalid timed action stops the whole queue"
end

-- Called for a queued action that never started when the queue empties.
function Wait:forceCancel()
    noteLostWait(self)
    ISBaseTimedAction.forceCancel(self)
end

function Wait:stop()
    noteLostWait(self)
    ISBaseTimedAction.stop(self)
end

-- What T.batch's fn queues with these three may be crossed (see sendAhead); the library's own
-- waits never are.

--- Queues `ticks` ticks of waiting, calling `onTick(n)` every tick.
function T.wait(ticks, onTick)
    queueWait(ticks, onTick).crossable = batching
end

--- Queues a wait that ends as soon as `condition()` holds, or after `maxFrames` ticks; the
--- following validate checks what it waited for. `what`, if given, says what it waits for when
--- the runner's per-test limit stops it (T.describeAction).
function T.waitUntil(condition, maxFrames, what)
    queueWait(maxFrames, nil, condition, what).crossable = batching
end

--- What a queued action is, for the runner's message when a test overruns its limit: a harness
--- wait's `what`, else where the wait or step was queued, else the action's type.
function T.describeAction(action)
    if not action then
        return "nothing queued"
    end
    if action.Type ~= Wait.Type then
        return tostring(action.Type)
    end
    if action.what then
        return action.what
    end
    local fn = action.done or action.onTick
    local file = fn and tostring(getFilenameOfClosure(fn)):match("[^/]*$")
    return "a wait queued at " .. tostring(file) .. ":" .. tostring(fn and getFirstLineOfClosure(fn))
end

--- Runs `fn` once the actions queued before it are done. What fn queues (actions, T.server,
--- T.step...) runs right after it, in order, before what was queued after the step.
function T.step(fn)
    queueWait(1, function() fn() end).crossable = batching
end

local function lit()
    return not T.player():tooDarkToRead()
end

-- Queues a wait until it is light (`wantLit`) or dark where the character stands, or LIGHT_MS
-- pass.
local function waitForLight(wantLit)
    local sinceMs
    queueWait(math.huge, nil, function()
        sinceMs = sinceMs or getTimestampMs()
        return lit() == wantLit or getTimestampMs() - sinceMs > LIGHT_MS
    end)
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

-- Whether a call queued after the action at `index` (the current one unless given) has gone out
-- ahead of its turn (sendAhead), so a request sent now would reach the server after it.
local function overtaken(index)
    local queue = ISTimedActionQueue.getTimedActionQueue(T.player()).queue
    for i = (index or 1) + 1, #queue do
        if queue[i].sentAhead then
            return true
        end
    end
    return false
end

-- Sends the call of the server handler `name` at once and handles its answer: the server's undo
-- as soon as it comes, so the undos stay in the order the calls went out; then, once the returned
-- condition is polled, a failure (as T.need does, dropping the steps queued after it),
-- `onReply(reply)` with the reply exactly as the handler returned it (false, 0 and nil too), and
-- the items a table reply lists as `given` (PZHarness.giveItem): once the client has them, worn
-- and held as they should be (the server dresses the character only then, "PZHarness.dress"),
-- their client copies land in self.items[itemsKey]. A call sent ahead of its turn takes its
-- answer only in its turn. `index` is where in the action queue the call is queued, if not the
-- current action. Returns the condition a queued wait polls until all of it is done.
local function call(self, name, args, itemsKey, onReply, index)
    local phase, given, sinceMs, asked, answer, onAnswer = "asking", nil, nil, nil, nil, nil
    local function fail(what)
        T.need(self, nil, what)
        dropQueuedSteps()
        phase = "done"
    end
    local function ask(handler, handlerArgs, onAnswered, at)
        if overtaken(at) then
            fail("the server's " .. handler .. " in its turn: T.batch had sent the calls queued after it already")
            return
        end
        phase, asked, answer, onAnswer = "asking", handler, nil, onAnswered
        PZHarness.ServerCalls.send("call", { name = handler, test = self.name, args = handlerArgs }, function(reply)
            if reply.undo then
                local function undo() unwindOnServer(self, handler, reply.id) end
                -- An answer can come after the verdict once a missing fixture ended the test's waits.
                if self.unwound then undo() else T.defer(self, undo) end
            end
            answer = reply
        end)
    end
    ask(name, args or {}, function(reply)
        if onReply then
            onReply(reply)
        end
        given, sinceMs = type(reply) == "table" and reply.given or nil, getTimestampMs()
        phase = given and "receiving" or "done"
    end, index)
    return function()
        if phase == "asking" then
            if not answer then
                return false
            end
            if answer.error or answer.missing then
                fail(answer.missing or "the server's " .. asked .. ", which failed: " .. answer.error)
            else
                onAnswer(answer.reply)
            end
        end
        if phase == "receiving" or phase == "dressing" then
            local items = clientCopies(given)
            if items and phase == "receiving" and needsDressing(given) then
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

-- Queues one wait that sends a call in its turn, once the actions queued before it are done, or
-- before that when `args` is a table (sendAhead), and takes its answer in its turn: a call whose
-- answer is in already costs a single tick. `args` may be a function of `self`. Calls queued
-- after it may go out before its answer when `crossable`, or in T.batch.
local function queueCall(self, name, args, itemsKey, onReply, crossable)
    local poll
    local function send(index)
        poll = call(self, name, type(args) == "function" and args(self) or args or {}, itemsKey, onReply, index)
    end
    -- The answer, or the error ServerCalls gives a lost one, always comes, so no frame cap. A wait
    -- that a missing fixture ends sends nothing.
    local wait = queueWait(math.huge, function()
        if not poll then
            send()
        end
    end, function() return poll() end, "the server's answer to " .. name)
    if type(args) ~= "function" then
        wait.crossable = crossable or batching
        wait.ahead = function(index)
            if not poll then
                wait.sentAhead = true
                send(index)
            end
        end
    end
end

--- Queues a call of the server handler `name` (see server/PZHarness/ServerHandlers.lua) and a
--- wait for its answer, which lands in `self.server[name]` exactly as the handler returned it, so
--- a handler's false, 0 or nil reaches the test as that. `args` is a table of plain values
--- (strings, numbers, booleans and tables of them), or a function of `self` returning one, called
--- when the call goes out, so it can use an earlier answer. In single player the handler runs in
--- this game and answers at once; in multiplayer it runs on the server. A call with a table goes
--- out early when nothing but waits for the server's answers to the setters, T.give or T.count is
--- queued before it, or in T.batch; its answer still lands in its turn. What it deferred is
--- undone on its side when the test ends, in order with the test's own undos. A handler that
--- fails, or answers that something is missing, fails the test as T.need does and drops the steps
--- queued after the call. A handler that gave the character items lists them in its reply as
--- `given` (PZHarness.giveItem); the wait then lasts until this client has them, worn and held as
--- asked, and puts this client's copies in `self.items[name]`.
function T.server(self, name, args)
    queueCall(self, name, args, name, function(reply) self.server[name] = reply end)
end

--- Queues what `fn` queues, and in multiplayer sends each server call in it (T.server, T.give,
--- T.count and the fixtures built on them) whose args are a table as soon as the actions queued
--- before the batch are done, all in one round trip, where each would otherwise wait for the
--- answer to the one before. The server still runs them in their order, each with its undos, and
--- each answer lands in its turn, so a T.step between two calls reads the first one's answer. Only
--- for calls the test makes back to back: the server runs every call in the batch before anything
--- fn queued between them happens on this client, so a wait in it for this client's copy may see
--- what the later calls did too, and a call whose args are a function goes out in its turn,
--- holding back the calls after it. A T.step in it must not reach the server (a call it queues, a
--- setter, an action), and only the batch's last call may give items to put on or hold, since
--- they go on in its turn: either would reach the server after the calls queued behind it, which
--- fails the test.
function T.batch(fn)
    local outer = batching
    batching = true
    fn()
    batching = outer
end

--- Queues calls of the server handler `name`, one at a time, until `done(reply)` holds or `maxMs`
--- of real time (15 seconds unless given) pass, for server state that changes later, such as what
--- an action's complete() does after the client's perform(). The last reply lands in
--- `self.server[name]`; running out of time just ends the wait, so validate checks what it waited
--- for. `args` as for T.server; a failed call fails the test as T.server's does.
function T.serverUntil(self, name, args, done, maxMs)
    local poll, sinceMs
    queueWait(math.huge, nil, function()
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
    end, "the server's answers to " .. name)
end

--- Gives the character `items` the way the server does: each a table { type = full type, count,
--- uses (fraction of a full drainable item), condition, modData (keys to set), worn = true,
--- equip = "primary", "secondary" or "both" }. Queued like T.server; this client's copies land in
--- `self.items[name]`, `count` of each in the order given. In multiplayer the server makes them,
--- sends them here and then puts them on and in hand, so actions that run on the server find them.
--- The runner empties the inventory before the next test.
function T.give(self, name, items)
    local dresses = false
    for _, item in ipairs(items) do
        dresses = dresses or item.worn or item.equip ~= nil
    end
    queueCall(self, "PZHarness.give", { items = items }, name, nil, not dresses)
end

--- Queues a count of each of `types` in the inventory of the server's copy of the character, bags
--- included, into `self.counts[name][fullType]`. With `opts.dropped`, items dropped on the squares
--- around the character count too and go away, as a craft drops what doesn't fit.
function T.count(self, name, types, opts)
    queueCall(self, "PZHarness.count", { types = types, dropped = opts and opts.dropped or nil }, nil, function(reply)
        self.counts[name] = reply.counts
    end, true)
end

-- The server's half of a two-sided fixture (server/PZHarness/ServerFixtures.lua), on a
-- multiplayer client only: sent at once, so it reaches the server before any later T.server call,
-- with a wait for its answer queued, so the actions queued after the fixture start only once the
-- server has made the change. Server calls queued after it may go out before that (sendAhead).
-- Single player has made it already, in its one copy.
local function alsoOnServer(self, name, args, onReply)
    if isClient() then
        queueWait(math.huge, nil, call(self, name, args, nil, onReply), "the server's answer to " .. name).crossable = true
    end
end

-- The same for two-sided helpers that take no test, which scenarios call too: a failure prints a
-- FAIL line of its own. `ready(reply)`, if given, holds once this client has what the server did.
local function alsoOnServerOutsideTest(name, args, ready)
    if not isClient() then
        return
    end
    local answered, reply, sinceMs = false, nil, nil
    PZHarness.ServerCalls.callOutsideTest(name, args, function(answer)
        answered, reply, sinceMs = true, answer, getTimestampMs()
    end)
    queueWait(math.huge, nil, function()
        if not answered then
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
    end, "the server's answer to " .. name)
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

--- Sets the character's level of `perk` for the test. On a multiplayer client the server replaces
--- this client's perk list with its own copy's every second (PlayerXpPacket), and one it sent
--- before it had the level can land after its answer, so the client's checks (the craft menu, an
--- action's isValid) would see the old level: until the test ends, this client puts its level
--- back whenever such a sync changes it. Waiting for a sync after the answer would cost up to a
--- second per call.
function T.setPerk(self, perk, level)
    local p = T.player()
    T.defer(self, PZHarness.Fixtures.setPerk(p, perk, level))
    alsoOnServer(self, "PZHarness.setPerk", { perk = perk:getId(), level = level })
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
--- game. An option in neither is recorded as missing rather than created. Each side calls the
--- `sandboxChanged` setting after its copy changes.
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

--- Vanilla's mechanics cheat on or off for the character, on both sides (Fixtures.setMechanicsCheat).
--- A multiplayer server times a vehicle part's install and uninstall in real time, and the instant
--- cheat can't shorten them there: an instant action on a client checks isValid again once the
--- server has moved the part, fails, and empties the action queue. The mechanics cheat skips that
--- check, so a test turns it on around the action, after reading canInstallPart and
--- canUninstallPart itself.
function T.setMechanicsCheat(self, on)
    T.defer(self, PZHarness.Fixtures.setMechanicsCheat(T.player(), on))
    alsoOnServer(self, "PZHarness.setMechanicsCheat", { on = on })
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
    alsoOnServer(self, "PZHarness.setGrid", { on = on })
    if not on then
        dropStaleGeneratorPower()
    end
end

--- Midnight with the grid off, dark where the character stands; queues a wait for the light to
--- follow the clock.
function T.makeDark(self)
    T.setGrid(self, false)
    T.setTime(self, 0)
    waitForLight(false)
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

-- The spec's own start of a test, once the light has caught up: the instant cheat, the hour, the
-- sandbox options, the mod's setup, then spec.run unless a fixture is already missing.
local function startSpec(self, spec, hour)
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

-- The runner's run of a registered test: a fresh `self`, an undo that gives back the perks of the
-- `perks` setting, then startSpec. A malformed opt-out runs nothing; validate reports it.
local function runEntry(entry, name, spec, problem)
    local self = { name = name, undo = {}, missing = {}, used = {}, server = {}, items = {}, counts = {},
        startedMs = getTimestampMs() }
    entry.state = self
    active = self
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
    -- back the levels it had: this client's can be a perk sync behind the server's.
    T.defer(self, function() PZHarness.Fixtures.setPerkLevels(p, perks) end)
    if #ids > 0 then
        alsoOnServer(self, "PZHarness.keepPerkLevels", { perks = ids })
    end
    -- Read now, not when the test registers: the dev mod may register its settings after its test
    -- files have loaded.
    local hour = spec.hour or settings().hour
    -- The light lags a clock or grid change by some frames, and the previous test may have ended
    -- in the dark.
    if not hour or lit() then
        startSpec(self, spec, hour)
    else
        waitForLight(true)
        T.step(function() startSpec(self, spec, hour) end)
    end
end

-- Runs the test's restore stack newest first. A server undo that single player answers at once
-- still lands in this test's failures while `unwinding` is set.
local function unwindTest(self)
    unwinding = true
    for i = #self.undo, 1, -1 do
        self.undo[i]()
    end
    unwinding = false
    self.unwound = true
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
    unwindTest(self)
    active = nil
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
    if not center or count < 1 then return found end
    local z = center:getZ()
    for radius = opts.minDistance or 1, SEARCH_RADIUS do
        for x, y in PZHarness.Fixtures.ring(center:getX(), center:getY(), radius) do
            local square = getSquare(x, y, z)
            if square and not self.used[square]
                and isFreeSquare(square, opts.indoors == true)
                and (not opts.bare or square:getObjects():size() == 1) then
                self.used[square] = true
                table.insert(found, square)
                if #found == count then
                    return found
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
--- mods' removal handlers run (PZHarness.Fixtures.removePlaced). Returns `thing`.
function T.track(self, thing)
    T.defer(self, function() PZHarness.Fixtures.removePlaced(thing) end)
    return thing
end

--- A tile object of `sprite` on `square`, with `modData`.
function T.tile(self, square, sprite, modData)
    return T.track(self, PZHarness.Fixtures.newTile(square, sprite, modData))
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
    local square = PZHarness.Fixtures.freeAdjacentSquare(T.player():getSquare(), self.used)
    if square then
        self.used[square] = true
    end
    return T.need(self, square, "a free square next to the character for a " .. entity)
end

--- A workstation of the entity script `entity` (such as "Base.Kiln_Small"), drawn as `sprite`,
--- on a free square next to the character, who is using it as its crafting window makes them.
--- Returns the object. On a multiplayer client it exists here only: use T.placeBench.
function T.bench(self, entity, sprite)
    local square = benchSquare(self, entity)
    if not square then
        return nil
    end
    local bench, missing = PZHarness.Fixtures.newBench(square, entity, sprite, T.player())
    if bench then
        T.track(self, bench)
    end
    return T.need(self, not missing and bench, missing)
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
    queueWait(math.huge, nil, function()
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
    end, "this client's copy of " .. what)
    return handle
end

--- A tile object of `sprite` on `square`, with `modData`, placed the way the authority does: on
--- the server in multiplayer, which sends it to the clients. Removed when the test ends as T.track
--- removes, by the dev mod's `remove` setting if it takes it, else the vanilla way. Returns a
--- handle { x, y, z, square } at once; handle.object is this client's copy, there at once in
--- single player and after a queued wait in multiplayer.
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

-- Queues a wait until `condition()` holds on this client, at most RECEIVE_MS.
local function waitOnClient(condition)
    local sinceMs
    queueWait(math.huge, nil, function()
        sinceMs = sinceMs or getTimestampMs()
        return condition() or getTimestampMs() - sinceMs > RECEIVE_MS
    end)
end

--- Puts the character in the middle of the free square next to `square` that vanilla's walkAdj
--- would walk it to (AdjacentFreeTileFinder.Find), or of its own square if there is none, so the
--- walk that a menu option or an action queues before its job has no way to go. Walking takes
--- real time, which neither the instant cheat nor the frame rate shortens.
function T.standNextTo(square)
    local p = T.player()
    local adjacent = AdjacentFreeTileFinder.Find(luautils.getCorrectSquareForWall(p, square), p)
    local at = adjacent or p:getCurrentSquare()
    PZHarness.Fixtures.teleportToMiddle(p, at:getX(), at:getY(), at:getZ())
end

--- Queues T.standNextTo(square), then a wait until a multiplayer server has the character there
--- too. The server learns the character moved only from the client's position updates, after any
--- still on their way, and an instant timed action queued at once can reach its complete() on the
--- server while it still stands at the old place.
function T.goNextTo(self, square)
    local at = {}
    T.step(function()
        T.standNextTo(square)
        -- The character's square catches up with a teleport only on its next update.
        local p = T.player()
        at.x, at.y = math.floor(p:getX()), math.floor(p:getY())
    end)
    T.serverUntil(self, "PZHarness.position", {}, function(reply)
        return math.floor(reply.x) == at.x and math.floor(reply.y) == at.y
    end)
end

-- Queues the moveables action `mode` ("place" or "pickup") of `sprite` on `square` the way the
-- moveables cursor does (ISMoveableCursor.create): the character walks next to the square and the
-- action does the job, in multiplayer in its complete() on the server. The character first stands
-- next to the square (T.standNextTo), in the middle of a square, as vanilla's walkAdj misjudges the
-- reach from a square's edge. Returns false if the character can't get there.
local function moveablesAction(square, mode, sprite, item, object)
    local p = T.player()
    T.standNextTo(square)
    local props = object and ISMoveableSpriteProps.fromObject(object) or ISMoveableSpriteProps.new(sprite)
    if not props:walkToAndEquip(p, square, mode, sprite) then
        return false
    end
    local direction = props:getFaceDirectionFromSpriteName(sprite)
    ISTimedActionQueue.add(ISMoveablesAction:new(p, square, mode, sprite, object, direction, item, nil))
    return true
end

--- Queues placing a new `itemType`, with `modData` on the item, on `square` the way a player does:
--- the character is given it (T.give), walks next to the square and places it with the moveables
--- action, which a multiplayer server carries out. What it placed goes when the test ends, as
--- T.placeTile's does. Returns a handle { x, y, z, square } at once; handle.object is this client's
--- copy of the placed object, drawn as `sprite`, once it has arrived.
function T.placeAsPlayer(self, square, itemType, sprite, modData)
    self.placedAsPlayer = (self.placedAsPlayer or 0) + 1
    local key = "PZHarness.placeAsPlayer" .. self.placedAsPlayer
    local handle = { x = square:getX(), y = square:getY(), z = square:getZ(), square = square }
    T.give(self, key, { { type = itemType, modData = modData } })
    queueWait(1, function()
        if not T.need(self, moveablesAction(square, "place", sprite, self.items[key][1], nil), "a way to place a " .. itemType) then
            return
        end
        waitOnClient(function() return T.objectWithSprite(square, sprite) ~= nil end)
        T.server(self, "PZHarness.trackPlaced", { x = handle.x, y = handle.y, z = handle.z, sprite = sprite })
        queueWait(1, function()
            handle.object = T.need(self, T.objectWithSprite(square, sprite), "this client's copy of a placed " .. itemType)
        end)
    end)
    return handle
end

--- Queues picking up the object drawn as `sprite` on `at` (a square, or a handle with a `square`)
--- the way a player does, with the moveables action, and a wait until this client no longer has
--- it.
function T.pickUpAsPlayer(self, at, sprite)
    local square = type(at) == "table" and at.square or at
    queueWait(1, function()
        local object = T.objectWithSprite(square, sprite)
        if not T.need(self, object and moveablesAction(square, "pickup", sprite, nil, object), "a way to pick up the " .. sprite) then
            return
        end
        waitOnClient(function() return T.objectWithSprite(square, sprite) == nil end)
    end)
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

-- This client's copies of the vehicles T.placeVehicle found, to the handle each was found for.
-- The server hands a new vehicle the id it freed last (VehicleIDMap keeps freed ids on a stack),
-- often the one the previous test's undo just removed, and a client that hasn't taken that
-- removal yet still finds the old copy under the id, which then never updates. A copy found for
-- one handle is never taken for another. Kahlua has no weak tables, so T.placeVehicle drops the
-- copies this client has removed, which nothing can find again.
local foundVehicles = {}
-- How long a multiplayer client waits after its copy of a new vehicle arrives, for the server's
-- second full update of it (see T.placeVehicle): three of the server's 100 ms send cycles.
local VEHICLE_SETTLE_MS = 300

--- T.vehicle placed the way the authority does: on the server in multiplayer, which sends it to
--- the clients nearby; removed when the test ends. `opts`: `square` or `near` as for T.vehicle,
--- `facing` ("N" unless given), `args` (plain values for the dev mod's `spawnVehicle` setting,
--- which makes the vehicle if it returns one). Returns a handle at once. Once the server has
--- answered, handle.id (shared by the server and its clients; PZHarness.Fixtures.vehicleById
--- finds it on either side), x, y, z and square say where it went, and after a queued wait
--- handle.vehicle is this client's copy.
function T.placeVehicle(self, script, opts)
    opts = opts or {}
    local removed = {}
    for vehicle in pairs(foundVehicles) do
        if vehicle:isRemovedFromWorld() then
            table.insert(removed, vehicle)
        end
    end
    for _, vehicle in ipairs(removed) do
        foundVehicles[vehicle] = nil
    end
    local squares = {}
    for _, square in ipairs(vehicleSquares(self, opts)) do
        table.insert(squares, { x = square:getX(), y = square:getY(), z = square:getZ() })
    end
    local handle = {}
    local args = { script = script, squares = squares, facing = opts.facing, args = opts.args }
    placeOnServer(self, handle, "PZHarness.vehicle", args, function()
        local vehicle = PZHarness.Fixtures.vehicleById(handle.id, handle)
        if not vehicle or vehicle:isRemovedFromWorld() or (foundVehicles[vehicle] or handle) ~= handle then
            return nil
        end
        foundVehicles[vehicle] = handle
        return vehicle
    end, "a " .. script, "vehicle", function(reply)
        handle.id, handle.x, handle.y, handle.z = reply.id, reply.x, reply.y, reply.z
        handle.square = getSquare(reply.x, reply.y, reply.z)
    end)
    -- A client that meets a vehicle id it doesn't know asks for a full update, and can ask twice.
    -- The server sends the second instead of the part changes it has pending and clears them,
    -- while a client that already has the vehicle takes only its position from a full update
    -- (VehicleManager.sendVehicles, VehicleFullUpdatePacket): a part change made before the second
    -- one arrives is lost here until that part changes again. The server sends every 100 ms.
    if isClient() then
        local sinceMs
        queueWait(math.huge, nil, function()
            sinceMs = sinceMs or getTimestampMs()
            return getTimestampMs() - sinceMs >= VEHICLE_SETTLE_MS
        end, "the second full update of a " .. script)
    end
    return handle
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

--- The script Item the harness gives for `input`, a recipe's InputScript, or nil when it has no
--- possible item: the first of its possible items listed in `prefer` (full names), else its first
--- possible item other than a generic Base.Moveable, else its first.
function T.inputItem(input, prefer)
    local possible = input:getPossibleInputItems()
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

--- What one craft of `recipe` takes, tools included, as T.give items: each input gets
--- T.inputItem's choice; a drainable input that counts uses gets one full item. Also returns the
--- inputs that had no possible item at all.
function T.recipeInputs(recipe, prefer)
    local items, unmatched = {}, {}
    local inputs = recipe:getInputs()
    for i = 0, inputs:size() - 1 do
        local input = inputs:get(i)
        local item = T.inputItem(input, prefer)
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
--- exist on this client only, and a queued wait lasts until this client has it. Without a free
--- square it prints a FAIL line of its own, as a failed server call outside a test does.
function T.placeWorkTable(player)
    if PZHarness.Fixtures.workTableNear(player) then
        return
    end
    if not isClient() then
        if not PZHarness.Fixtures.placeWorkTable(player) then
            print(PZHarness.run.tag .. " FAIL PZHarness.workTable: no free square next to the character for a work table")
            PZHarness.ServerCalls.lateFailures = PZHarness.ServerCalls.lateFailures + 1
        end
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
    -- A player's right-click comes after the UI has drawn, by when the inventory windows list the
    -- containers around where the character is now and faces; at the uncapped frame rate a test
    -- can get here first.
    PZHarness.refreshInventoryWindows()
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

local function addRefusal(self, recipe, reason)
    self.refusal = (self.refusal and self.refusal .. "; " or "") .. recipe:getName() .. ": " .. reason
end

-- What stops a craft at perform, where the game checks the recipe again and gives up without a
-- word (HandcraftLogic.performCurrentRecipe, CraftRecipeData.perform): the start's check doesn't
-- look at the reach of the containers, and the rest can change while the craft is queued.
local function performProblems(action, recipe)
    local p, problems = action.character, {}
    if not p:isRecipeActuallyKnown(recipe) then
        table.insert(problems, "recipe not known")
    end
    if not recipe:characterHasRequiredSkills(p) then
        table.insert(problems, "skills too low")
    end
    if not recipe:canBeDoneInDark() and p:tooDarkToRead() then
        table.insert(problems, "too dark")
    end
    local containers = action.logic and action.containers
    for i = 0, (containers and containers:size() or 0) - 1 do
        local container = containers:get(i)
        local one = ArrayList.new()
        one:add(container)
        if not action.logic:isContainersAccessible(one) then
            local outer = container:getOutermostContainer()
            local part, square = outer:getVehiclePart(), outer:getSquare()
            table.insert(problems, "the " .. tostring(container:getType()) .. " container out of reach"
                .. (part and " (vehicle part " .. part:getId() .. ")" or "")
                .. (square and string.format(" at %d,%d", square:getX(), square:getY()) or ""))
        end
    end
    return problems
end

-- Watches the crafts `start()` queues, so that one the game queued and then dropped says whether
-- it never performed or what was wrong when it did.
local function watchCrafts(self, recipe, start)
    local queue = ISTimedActionQueue.getTimedActionQueue(T.player()).queue
    local queued = {}
    for _, action in ipairs(queue) do
        queued[action] = true
    end
    start()
    for _, action in ipairs(queue) do
        if not queued[action] and action.Type == "ISHandcraftAction" then
            local perform = action.perform
            function action.perform(a)
                a.harnessPerformed = true
                local problems = performProblems(a, recipe)
                if #problems > 0 then
                    addRefusal(self, recipe, "at perform, " .. table.concat(problems, ", "))
                end
                return perform(a)
            end
            T.step(function()
                if not action.harnessPerformed then
                    addRefusal(self, recipe, "queued but never performed")
                end
            end)
        end
    end
end

--- Starts crafting `recipe` from the item `from` the way the right-click menu does or, with
--- `bench` (from T.bench), the way the bench's crafting window does. Adds why the game refused
--- to `self.refusal`, which the test's failures then end with.
function T.startCraft(self, recipe, from, bench)
    local refusal = T.craftRefusal(recipe, from, bench)
    if refusal then
        addRefusal(self, recipe, refusal)
    end
    watchCrafts(self, recipe, function()
        if bench then
            ISEntityUI.HandcraftStart(T.player(), craftLogic(recipe, from, bench), false, true)
        else
            ISInventoryPaneContextMenu.OnNewCraft(from, recipe, T.player():getPlayerNum(), false)
        end
    end)
end

--- Registers a test that crafts `spec.recipe` from the first `spec.from` item the way the
--- right-click menu does or, with `spec.bench` ({ entity script, sprite }, see T.bench), at that
--- workstation the way its crafting window does; instantly unless `spec.instant` is false. The
--- character knows every recipe of the mod, has at least the levels the recipe requires, stands
--- by a table, and carries exactly the inputs of one craft (T.recipeInputs with `spec.prefer`,
--- given with T.give, so this client's copies are in `self.items.inputs`) and whatever
--- `spec.setup(self)` adds; setup runs once the inputs are there, and the craft starts after the
--- waits it queued, once there is light to craft by. validate() expects the counts in
--- `spec.counts` in the inventory of the server's copy of the character or dropped at its feet
--- (T.count, into `self.counts.craft`), then runs `spec.validate(self)`. `spec.after(self)`, if
--- given, runs in a step after that count, before validate, to queue more reads of what the
--- craft made. A failing test also reports why the game refused the craft.
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
            -- Once the first craft test has taught them all, learning them again would only cost
            -- a multiplayer client a server round trip.
            for _, name in ipairs(T.recipeNames()) do
                if not p:isRecipeActuallyKnown(name) then
                    T.learnRecipes(p)
                    break
                end
            end
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
                -- The light can still lag the clock the previous test put back, and the game
                -- refuses a craft in the dark; the test is about the craft, not the dusk.
                waitForLight(true)
                T.step(function()
                    local from = T.need(self, p:getInventory():getFirstTypeRecurse(spec.from), "a " .. spec.from .. " to craft from")
                    if not from then return end
                    T.startCraft(self, recipe, from, bench and bench.object)
                    -- Queued after the craft's actions, which T.startCraft has just queued.
                    T.count(self, "craft", counted, { dropped = true })
                    if spec.after then
                        T.step(function() spec.after(self) end)
                    end
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
