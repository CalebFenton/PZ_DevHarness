-- Development only, not published. The client's half of the tests' server channel; the server's
-- half, and how a dev mod registers handlers, is in server/PZHarness/ServerHandlers.lua. Tests use
-- it through PZHarness.Test.server, the runner for --stay reruns. In single player the server's
-- half runs in this Lua state and answers at once, in the same tick; in multiplayer a request
-- travels as a client command and its answer as a server command, a tick or more later.

PZHarness = PZHarness or {}
local ServerCalls = {}
PZHarness.ServerCalls = ServerCalls

local MODULE = "PZHarness"
-- An answer that takes longer is lost: the server logged why, or stopped.
local ANSWER_MS = 15000

-- Unanswered requests by id: { onAnswer, sentMs }.
local pending = {}
local lastId = 0

-- Failures that arrive after their test's verdict, such as a server undo that failed; the runner
-- counts them.
ServerCalls.lateFailures = 0

--- Sends a request of `kind` ("call", "unwind" or "reload") and calls `onAnswer(answer)` with the
--- server's answer, or with `{ error = ... }` if none comes.
function ServerCalls.send(kind, request, onAnswer)
    lastId = lastId + 1
    request.id = lastId
    request.tag = PZHarness.run.tag
    local player = getSpecificPlayer(0)
    if not isClient() then
        onAnswer(PZHarness.ServerHandlers.handle(player, kind, request))
        return
    end
    pending[lastId] = { onAnswer = onAnswer, sentMs = getTimestampMs() }
    sendClientCommand(player, MODULE, kind, request)
end

--- Whether a request is still waiting for its answer.
function ServerCalls.busy()
    for _ in pairs(pending) do
        return true
    end
    return false
end

local function answered(id, answer)
    local entry = pending[id]
    pending[id] = nil
    if entry then
        entry.onAnswer(answer)
    end
end

Events.OnServerCommand.Add(function(module, command, args)
    if module == MODULE and command == "reply" then
        answered(args.id, args)
    end
end)

Events.OnTick.Add(function()
    local now, lost = getTimestampMs(), {}
    for id, entry in pairs(pending) do
        if now - entry.sentMs > ANSWER_MS then
            table.insert(lost, id)
        end
    end
    for _, id in ipairs(lost) do
        answered(id, { id = id, error = "no answer from the server within " .. ANSWER_MS / 1000 .. " s" })
    end
end)

return ServerCalls
