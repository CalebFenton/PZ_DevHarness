-- Development only, not published. The client half of the tests' server channel; the server half
-- and handler registration live in server/PZHarness/ServerHandlers.lua. In single player the
-- server half runs in this Lua state and answers in the same tick; in multiplayer requests travel
-- as client commands and answers as server commands.
--
-- Client commands are reliable but unordered (PacketTypes.ClientCommand): two sent in one tick can
-- arrive swapped. So requests carry this Lua state's `session` and a sequential id, the server
-- serves them in id order, and answers reach callers in that order too. Requests can therefore be
-- pipelined, and a test's undos stay in the order they were made.

require "PZHarness/Trace"

PZHarness = PZHarness or {}
local ServerCalls = {}
PZHarness.ServerCalls = ServerCalls

local MODULE = "PZHarness"
-- An answer that takes longer is lost: the server logged why, or stopped.
local ANSWER_MS = 15000
local SESSION = getTimestampMs()

-- Unanswered requests by id: { onAnswer, kind, request, sentMs, answer, answeredMs }, `answer`
-- once it has come while an earlier request still waits for its own.
local pending = {}
local lastId = 0
-- Real milliseconds with at least one request unanswered, up to the last time none was, and since
-- when one has been unanswered now; overlapping requests count once.
local waitedMs, waitingSinceMs = 0, nil

-- Failures that arrive after their test's verdict, such as a server undo that failed; the runner
-- counts them.
ServerCalls.lateFailures = 0

--- Sends a request of `kind` ("call", "unwind" or "reload") and calls `onAnswer(answer)` with the
--- server's answer, or with `{ error = ... }` if none comes, after the answers to the requests
--- sent before it.
function ServerCalls.send(kind, request, onAnswer)
    lastId = lastId + 1
    request.id = lastId
    request.tag = PZHarness.run.tag
    local player = getSpecificPlayer(0)
    if not isClient() then
        local sentMs = getTimestampMs()
        local answer = PZHarness.ServerHandlers.handle(player, kind, request)
        PZHarness.Trace.call(kind, request, answer, sentMs, getTimestampMs())
        onAnswer(answer)
        return
    end
    request.session = SESSION
    if not ServerCalls.busy() then
        waitingSinceMs = getTimestampMs()
    end
    pending[lastId] = { onAnswer = onAnswer, kind = kind, request = request, sentMs = getTimestampMs() }
    sendClientCommand(player, MODULE, kind, request)
end

--- Whether a request is still waiting for its answer.
function ServerCalls.busy()
    for _ in pairs(pending) do
        return true
    end
    return false
end

--- Real milliseconds so far that some request was waiting for its answer, for the runner's summary
--- of where a run's time went. Always 0 in single player, which answers at once.
function ServerCalls.waitedMs()
    return waitedMs + (waitingSinceMs and getTimestampMs() - waitingSinceMs or 0)
end

--- Calls the server handler `name` for something outside any one test, such as the runner's reset
--- or a scenario's setup, and `onReply(reply)` with its reply, exactly as the handler returned it:
--- false, 0 or nil too. A failure prints a FAIL line of its own, which the runner counts as it
--- does a late undo's, and never calls onReply.
function ServerCalls.callOutsideTest(name, args, onReply)
    ServerCalls.send("call", { name = name, test = name, args = args or {} }, function(answer)
        local problem = answer.error or answer.missing
        if problem then
            print(PZHarness.run.tag .. " FAIL " .. name .. ": " .. tostring(problem))
            ServerCalls.lateFailures = ServerCalls.lateFailures + 1
        elseif onReply then
            onReply(answer.reply)
        end
    end)
end

-- Hands out the answers that have come, oldest request first, up to the first still unanswered.
-- An answer's caller may send more requests meanwhile, which come after.
local function deliver()
    while true do
        local first
        for id in pairs(pending) do
            if not first or id < first then
                first = id
            end
        end
        local entry = first and pending[first]
        if not (entry and entry.answer) then
            return
        end
        pending[first] = nil
        if not ServerCalls.busy() then
            waitedMs = waitedMs + getTimestampMs() - waitingSinceMs
            waitingSinceMs = nil
        end
        PZHarness.Trace.call(entry.kind, entry.request, entry.answer, entry.sentMs, entry.answeredMs)
        entry.onAnswer(entry.answer)
    end
end

local function answered(id, answer)
    local entry = pending[id]
    if entry then
        entry.answer, entry.answeredMs = answer, getTimestampMs()
        deliver()
    end
end

Events.OnServerCommand.Add(function(module, command, args)
    if module == MODULE and command == "reply" then
        answered(args.id, args)
    end
end)

-- Runs every frame of the whole game, nearly always with nothing pending, so it returns before
-- allocating anything then, and allocates only once an answer is lost.
Events.OnTick.Add(function()
    if not ServerCalls.busy() then
        return
    end
    local now, lost = getTimestampMs(), nil
    for id, entry in pairs(pending) do
        if not entry.answer and now - entry.sentMs > ANSWER_MS then
            lost = lost or {}
            table.insert(lost, id)
        end
    end
    if not lost then
        return
    end
    for _, id in ipairs(lost) do
        answered(id, { id = id, error = "no answer from the server within " .. ANSWER_MS / 1000 .. " s" })
    end
end)

return ServerCalls
