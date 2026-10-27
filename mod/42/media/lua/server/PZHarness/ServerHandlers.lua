-- Development only, not published. The server's half of the tests' server channel; the client's
-- half is client/PZHarness/ServerCalls.lua, and tests use it through PZHarness.Test.server. The
-- dev mod registers named handlers from its own server Lua:
--
--   require "PZHarness/ServerHandlers"
--   PZHarness.serverHandler("placeThing", function(player, args, defer)
--       local thing = ...                     -- build it the way the authority does
--       defer(function() ... end)             -- undone on the server when the calling test ends
--       return { x = ..., y = ... }           -- plain values only: they may cross the network
--   end)
--
-- A handler that lacks something ends with PZHarness.need(value, "a loaded square for the bank"),
-- which fails the test the way T.need does. In single player the client calls Handlers.handle in
-- the same Lua state; on a dedicated server the requests arrive as client commands and the answers go
-- back as server commands. The registry exists on a multiplayer client too, which loads server Lua
-- as well, so a dev mod's handler file needs no guard; only a server or single player answers.

PZHarness = PZHarness or {}
local Handlers = {}
PZHarness.ServerHandlers = Handlers

local MODULE = "PZHarness"

local handlers = {}
-- What each call's handler deferred, by caller and call id, until its test ends.
local undos = {}
-- What a handler's coroutine yields through PZHarness.need, which no handler returns.
local MISSING = {}

--- Registers `fn(player, args, defer)` as the server handler `name`, replacing any earlier one,
--- so a reloaded handler file takes effect.
function PZHarness.serverHandler(name, fn)
    handlers[name] = fn
end

--- `value`, unless it is nil or false: then the running handler ends, and its test fails as
--- missing `what` rather than as a server failure. A debug game stops at any Lua error, caught or
--- not, so this yields the handler's coroutine instead of raising. Kahlua yields only through Lua
--- calls (LuaCallFrame.canYield), so call it in the handler or a Lua function it calls, never
--- inside a pcall, a deferred undo, or a function the game calls back from Java (an event, an
--- Eval or a sort's comparator), where the yield itself fails.
function PZHarness.need(value, what)
    if value == nil or value == false then
        coroutine.yield(MISSING, tostring(what))
    end
    return value
end

--- Runs the registered handler `name` inside the running one, with its `player` and `defer`, and
--- returns its answer: for reads a handler takes before and after its change in the same call, so
--- no tick comes between them (PZHarness.readsAround). Ends the running handler as missing a
--- handler that isn't registered.
function Handlers.run(name, player, args, defer)
    local handler = PZHarness.need(handlers[name], "the server handler " .. tostring(name))
    return handler(player, args or {}, defer)
end

-- Each read of `reads` ({ [label] = { name, args } }) by label (Handlers.run).
local function readAll(player, reads, defer)
    local answers = {}
    for label, read in pairs(reads or {}) do
        answers[label] = Handlers.run(read.name, player, read.args, defer)
    end
    return answers
end

--- Runs the reads `reads` ({ [label] = { name = handler, args } }), then `change()`, then the
--- reads again, all in the running handler's one call, so no tick, pass or sync comes between.
--- Returns the answers before and after, by label, and what `change` returned.
function PZHarness.readsAround(player, reads, defer, change)
    local before = readAll(player, reads, defer)
    local result = change()
    return before, readAll(player, reads, defer), result
end

local function undoKey(player, id)
    return player:getUsername() .. "#" .. tostring(id)
end

-- Runs the undos newest first, each whatever the others do. Returns their errors.
local function unwind(list)
    local errors = {}
    for i = #list, 1, -1 do
        local ok, err = pcall(list[i])
        if not ok then
            table.insert(errors, tostring(err))
        end
    end
    return errors
end

local function call(player, request)
    local handler = handlers[request.name]
    if not handler then
        return { error = "no server handler " .. tostring(request.name) }
    end
    local list = {}
    local function defer(undo)
        table.insert(list, undo)
    end
    -- A coroutine, so that PZHarness.need can end it: it never resumes after that yield.
    local ok, reply, what = coroutine.resume(coroutine.create(handler), player, request.args or {}, defer)
    if not ok or reply == MISSING then
        -- What the handler built before it ended goes at once: no test unwinds a failed call.
        local errors = unwind(list)
        if ok then
            return { missing = what, error = #errors > 0 and table.concat(errors, "; ") or nil }
        end
        table.insert(errors, 1, tostring(reply))
        return { error = table.concat(errors, "; ") }
    end
    -- Only a call that left something to undo costs the test an unwind request.
    if #list > 0 then
        undos[undoKey(player, request.id)] = list
    end
    return { reply = reply, undo = #list > 0 }
end

local function unwindCall(player, request)
    local key = undoKey(player, request.call)
    local errors = unwind(undos[key] or {})
    undos[key] = nil
    return { error = #errors > 0 and table.concat(errors, "; ") or nil }
end

-- A --stay rerun: marks the run in the server's log, where run-client.sh reads this run's part
-- from, and loads the dev mod's reloadable server and shared files again. reloadLuaFile ignores a
-- file's Events.*.Add calls, so only files that just register handlers reload safely.
local function reload(_, request)
    if request.run then
        print(request.tag .. " RUN " .. request.run)
    end
    local errors = {}
    for _, file in ipairs(request.files or {}) do
        local ok, err = pcall(reloadLuaFile, file)
        if not ok then
            table.insert(errors, file .. ": " .. tostring(err))
        end
    end
    return { error = #errors > 0 and table.concat(errors, "; ") or nil }
end

local kinds = { call = call, unwind = unwindCall, reload = reload }

--- Serves one request of `player`'s client; `kind` is "call", "unwind" or "reload". Returns the
--- answer. A failure also goes to the server's log as "<tag> SERVER FAIL <test>: <error>", which
--- run-client.sh counts.
function Handlers.handle(player, kind, request)
    local answer = kinds[kind](player, request)
    answer.id = request.id
    if answer.error then
        print(tostring(request.tag) .. " SERVER FAIL " .. tostring(request.test or kind) .. ": " .. answer.error)
    end
    return answer
end

-- Client commands arrive reliably but in any order (PacketTypes.ClientCommand), so each client's
-- requests are served in the order of their ids within its session (client/PZHarness/
-- ServerCalls.lua), and one that comes early waits here for those before it: the next id and the
-- waiting requests of each player's session. Each answer carries when its request arrived, and
-- when its handler started and finished, for a TRACE run (client/PZHarness/Trace.lua).
local queues = {}

if isServer() then
    Events.OnClientCommand.Add(function(module, command, player, args)
        if module ~= MODULE or not kinds[command] or not args then
            return
        end
        local owner = player:getUsername()
        local queue = queues[owner]
        if not queue or queue.session ~= args.session then
            queue = { session = args.session, next = 1, early = {} }
            queues[owner] = queue
        end
        queue.early[args.id] = { command = command, args = args, arrivedMs = getTimestampMs() }
        while queue.early[queue.next] do
            local request = queue.early[queue.next]
            queue.early[queue.next] = nil
            queue.next = queue.next + 1
            local startedMs = getTimestampMs()
            local answer = Handlers.handle(player, request.command, request.args)
            answer.arrivedMs, answer.startedMs, answer.finishedMs = request.arrivedMs, startedMs, getTimestampMs()
            sendServerCommand(player, MODULE, "reply", answer)
        end
    end)
end

return Handlers
