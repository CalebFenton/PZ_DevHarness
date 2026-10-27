require "PZHarness/ServerCalls"
local Report = require "PZHarness/Report"

-- Internal runtime of TestLib: the action queue, ordered server calls and the active test's
-- lifetime. TestLib creates PZHarness.Test before loading this module; feature modules require
-- TestLib first. Only this module owns the active test, batching and server-undo state.
local T = PZHarness.Test
local Runtime = {}

-- The longest a test waits for the light to follow the clock or the grid, in real milliseconds. The
-- lighting catches up at its own pace in real time, whatever the frame rate, and on a multiplayer
-- client only after the server's clock has come back to it.
local LIGHT_MS = 10000
-- The longest T.waitFor waits unless told otherwise, in real milliseconds: how long this client may
-- take to show what the server changed. Waits count real time, since frames come faster or slower
-- with the uncapped frame rate.
local SYNC_MS = 10000
-- The test being run, from its run to its verdict.
local active
-- Whether T.batch is running its fn, so what it queues may be crossed (see sendAhead).
local batching = false

-- Queue

-- Holds the action queue, so the runner validates only once the world has caught up: until
-- `done()` holds or `total` ticks pass, calling `onTick(n)` every tick. What onTick queues goes
-- right after the wait, in order (vanilla's adding-actions mode, ISQueueActionsAction), and a
-- clear of the queue meanwhile, as luautils.walkAdj makes, drops only that. Once the running test
-- misses a fixture (T.need), every wait ends at once without calling anything, since what comes
-- after would work on the missing fixture.
local Wait = ISBaseTimedAction:derive("PZHarnessWait")

-- In multiplayer, sends server calls queued behind the current action ahead of their turn, each
-- once everything queued before it is `crossable`: an already-sent call whose answer changes
-- nothing on the server, or anything T.batch queued. The server keeps request order, so this only
-- removes round trips; each answer still reaches the test in its turn (see call). A call whose
-- args are a function goes out only in its turn, holding back everything after it.
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

function Runtime.wait(total, onTick, done, what)
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
    Runtime.wait(ticks, onTick).crossable = batching
end

-- Queues a wait that ends as soon as `condition()` holds, or once `maxMs` real milliseconds have
-- passed since its first tick. With `test`, timing out records missing `what` in that same
-- action, before any later step or server call can run.
function Runtime.waitUntil(condition, maxMs, what, test)
    local sinceMs
    local wait = Runtime.wait(math.huge, nil, function()
        sinceMs = sinceMs or getTimestampMs()
        if condition() then return true end
        if getTimestampMs() - sinceMs <= maxMs then return false end
        if test then T.need(test, nil, what) end
        return true
    end, what)
    wait.source = condition
    return wait
end

--- Queues a wait that ends as soon as `condition()` holds, or after `maxMs` real milliseconds; the
--- following validate checks what it waited for. `what`, if given, says what it waits for when
--- the runner's per-test limit stops it (T.describeAction).
function T.waitUntil(condition, maxMs, what)
    Runtime.waitUntil(condition, maxMs, what).crossable = batching
end

--- Queues a wait until `condition()` holds or `ms` real milliseconds pass (SYNC_MS unless given),
--- then fails the test as missing `what` (T.need) if it never held, so a copy that never came
--- can't pass where T.waitUntil just ends. The verdict is the condition's last answer: it isn't
--- called again, so what it noted when it held stays.
function T.waitFor(self, condition, what, ms)
    Runtime.waitUntil(condition, ms or SYNC_MS, what, self).crossable = batching
end

--- What a queued action is, for the runner's message when a test overruns its limit: a harness
--- wait's `what`, else where the step's function or the wait was written, else the action's type.
function T.describeAction(action)
    if not action then
        return "nothing queued"
    end
    if action.Type ~= Wait.Type then
        -- A walk stops when its path fails (ISWalkToTimedAction.update), so where it went says why.
        if action.Type == "ISWalkToTimedAction" then
            local from, to = action.character, action.location
            return string.format("ISWalkToTimedAction from %.1f,%.1f,%d to %d,%d,%d", from:getX(), from:getY(),
                from:getZ(), to:getX(), to:getY(), to:getZ())
        end
        return tostring(action.Type)
    end
    if action.what then
        return action.what
    end
    local fn = action.step or action.source or action.done or action.onTick
    local file = fn and tostring(getFilenameOfClosure(fn)):match("[^/]*$")
    return (action.step and "the step at " or "a wait queued at ") .. tostring(file) .. ":"
        .. tostring(fn and getFirstLineOfClosure(fn))
end

--- Runs `fn` once the actions queued before it are done. What fn queues (actions, T.server,
--- T.step...) runs right after it, in order, before what was queued after the step.
function T.step(fn)
    local wait = Runtime.wait(1, function() fn() end)
    wait.crossable, wait.step = batching, fn
end

function Runtime.lit()
    return not T.player():tooDarkToRead()
end

-- A condition that holds once it has been light (`wantLit`) or dark where the character stands
-- for two of the lighting thread's updates (LightingThread, PerformanceSettings.lightingFps). A
-- single reading can be a square's light from before a clock change, which the next update
-- replaces: a build has been seen refused in the dark one tick after a wait read it light.
local function steadyLight(wantLit)
    local sinceMs
    return function()
        if Runtime.lit() ~= wantLit then
            sinceMs = nil
            return false
        end
        sinceMs = sinceMs or getTimestampMs()
        return getTimestampMs() - sinceMs >= 2000 / getPerformance():getLightingFPS()
    end
end

-- Queues a wait until it is steadily light (`wantLit`) or dark where the character stands, or
-- LIGHT_MS pass.
function Runtime.waitForLight(wantLit)
    Runtime.waitUntil(steadyLight(wantLit), LIGHT_MS,
        wantLit and "light where the character stands" or "dark where the character stands")
end

--- Queues a wait until it is steadily light where the character stands, failing the test if it
--- never is: the game refuses a craft or a build in the dark (CraftRecipeData.canPerform), and the
--- light lags the clock the test before put back.
function T.waitForLight(self)
    T.waitFor(self, steadyLight(true), "light where the character stands", LIGHT_MS)
end

-- Server

-- How long the client may take, after the server's answer, to get the items a handler gave and to
-- show them worn and held.
local RECEIVE_MS = 15000

-- Whether the wrapper is unwinding a test's restore stack, so a server undo answered at once
-- (single player) still counts in the test's verdict.
local unwindingFailures

-- Takes back on the server what call `id` of handler `name` built. A multiplayer server answers
-- after the test's verdict, so a failure then is reported on its own line (Report.lateFailure).
local function unwindOnServer(self, name, id)
    PZHarness.ServerCalls.send("unwind", { test = self.name, call = id }, function(answer)
        if not answer.error then
            return
        end
        local failure = "the server's undo of " .. name .. " failed: " .. answer.error
        if unwindingFailures then
            table.insert(unwindingFailures, failure)
        else
            Report.lateFailure(self.name, failure)
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

-- Sends the call of server handler `name` at once. Its undo is pushed as soon as the answer comes,
-- keeping undos in send order; the rest is handled in turn, when the returned condition is polled:
-- a failure (as T.need), `onReply(reply)` with the raw reply, and any `given` items, whose client
-- copies land in self.items[itemsKey] once worn and held as asked. `index` is the call's position
-- in the action queue if not the current action. Returns the condition a queued wait polls.
-- `completion`, when present, polls its condition with the reply after the call and its items
-- finish; its independent deadline starts at the first incomplete client reading.
function Runtime.call(self, name, args, itemsKey, onReply, index, completion)
    local phase, given, sinceMs, asked, answer, onAnswer = "asking", nil, nil, nil, nil, nil
    local items, result, readySinceMs
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
        result = reply
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
            items = items or clientCopies(given)
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
        if phase == "done" and completion and #self.missing == 0 and not completion.ready(result) then
            readySinceMs = readySinceMs or getTimestampMs()
            if getTimestampMs() - readySinceMs <= completion.ms then return false end
            fail(completion.what)
        end
        return phase == "done"
    end
end

-- Queues one wait that sends a call in its turn, once the actions queued before it are done, or
-- before that when `args` is a table (sendAhead), and takes its answer in its turn: a call whose
-- answer is in already costs a single tick. `args` may be a function of `self`. Calls queued
-- after it may go out before its answer when `crossable`, or in T.batch.
local function queueCall(self, name, args, itemsKey, onReply, crossable, completion)
    local poll
    local function send(index)
        poll = Runtime.call(self, name, type(args) == "function" and args(self) or args or {}, itemsKey, onReply, index, completion)
    end
    -- The answer, or the error ServerCalls gives a lost one, always comes, so no frame cap. A wait
    -- that a missing fixture ends sends nothing.
    local wait = Runtime.wait(math.huge, function()
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

--- Queues a call of server handler `name` (see server/PZHarness/ServerHandlers.lua) and a wait
--- for its answer, which lands in `self.server[name]` exactly as returned (false, 0 and nil too).
--- `args` is a table of plain values, or a function of `self` returning one, called when the call
--- goes out so it can use an earlier answer. Runs locally in single player, on the server in
--- multiplayer. The handler's deferred undos run when the test ends, in order with the test's own.
--- A handler that fails or reports something missing fails the test as T.need does. Items the
--- handler lists as `given` (PZHarness.giveItem) are awaited on this client and land in
--- `self.items[name]`.
--- With `ready(reply)`, holds the same action until that client's reading succeeds; otherwise
--- fails as missing `what` after `ms` real milliseconds (SYNC_MS unless given).
function T.server(self, name, args, ready, what, ms)
    local completion = ready and { ready = ready, what = what or "this client's result of " .. name, ms = ms or SYNC_MS }
    queueCall(self, name, args, name, function(reply) self.server[name] = reply end, false, completion)
end

--- Queues what `fn` queues, and in multiplayer sends every table-args server call in it at once,
--- in one round trip instead of one per call. The server still runs them in order and each answer
--- lands in its turn. Use only for back-to-back calls: the server runs the whole batch before
--- anything queued between the calls happens on this client. A T.step inside must not reach the
--- server, and only the last call may give items to wear or hold; otherwise the test fails.
function T.batch(fn)
    local outer = batching
    batching = true
    fn()
    batching = outer
end

--- Queues calls of the server handler `name`, one at a time, until `done(reply)` holds or `maxMs`
--- of real time pass, for server state that changes later, such as what
--- an action's complete() does after the client's perform(). The last reply lands in
--- `self.server[name]`; running out of time just ends the wait, so validate checks what it waited
--- for. `args` as for T.server; a failed call fails the test as T.server's does.
function T.serverUntil(self, name, args, done, maxMs)
    local poll, sinceMs
    Runtime.wait(math.huge, nil, function()
        sinceMs = sinceMs or getTimestampMs()
        if poll then
            if not poll() then
                return false
            end
            if #self.missing > 0 or done(self.server[name]) or getTimestampMs() - sinceMs > (maxMs or RECEIVE_MS) then
                return true
            end
        end
        poll = Runtime.call(self, name, type(args) == "function" and args(self) or args or {}, name, function(reply)
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
function Runtime.alsoOnServer(self, name, args, onReply)
    if isClient() then
        Runtime.wait(math.huge, nil, Runtime.call(self, name, args, nil, onReply), "the server's answer to " .. name).crossable = true
    end
end

-- The same for two-sided helpers that take no test, which scenarios call too: a failure prints a
-- FAIL line of its own. `ready(reply)`, if given, holds once this client has what the server did.
function Runtime.outside(name, args, ready)
    if not isClient() then
        return
    end
    local answered, reply, sinceMs = false, nil, nil
    PZHarness.ServerCalls.callOutsideTest(name, args, function(answer)
        answered, reply, sinceMs = true, answer, getTimestampMs()
    end)
    Runtime.wait(math.huge, nil, function()
        if not answered then
            return not PZHarness.ServerCalls.busy()
        end
        if not ready or ready(reply) then
            return true
        end
        if getTimestampMs() - sinceMs > RECEIVE_MS then
            Report.lateFailure(name, "this client never got what the server did")
            return true
        end
        return false
    end, "the server's answer to " .. name)
end

-- Entered by the test wrapper before setup queues any actions.
function Runtime.begin(self)
    active = self
end

-- A synchronous server undo still belongs to this verdict; asynchronous failures report later.
function Runtime.finish(self, failures)
    unwindingFailures = failures
    for i = #self.undo, 1, -1 do
        self.undo[i]()
    end
    unwindingFailures = nil
    self.unwound = true
    active = nil
end

return Runtime
