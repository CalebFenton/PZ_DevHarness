-- Development only, not published. With TRACE=1, bin/run-client.sh has a --test run record where
-- its time goes in <cachedir>/Lua/PZHarnessTrace.txt (getFileWriter takes only a few extensions,
-- not .tsv), which lib/trace.py reports on. A multiplayer server adds its own times to every
-- answer (server/PZHarness/ServerHandlers.lua); client and server read the same clock, the
-- machine's.
--
-- One tab-separated record a line, times in real milliseconds, "-" for a time there is none of:
--   test   <name> <start> <end> <frames>
--   action <test> <start> <end> <frames> <what>   what headed the action queue (T.describeAction)
--   gap    <what> <start> <end>                   between tests: "reset", then "leaks"
--   call   <test> <id> <kind> <name> <sent> <arrived> <started> <finished> <answered> <delivered>
-- A call arrived at the server, its handler started after the requests before it and finished,
-- the answer reached this client, then its caller once the answers before it had.

PZHarness = PZHarness or {}
local Trace = {}
PZHarness.Trace = Trace

local FILE = "PZHarnessTrace.txt"

local writer
-- The action heading the queue: the action, its test and description, since when and which frame.
local head, headTest, headWhat, headMs, headFrame

local function field(value)
    if value == nil then
        return "-"
    end
    if type(value) == "number" then
        return string.format("%.0f", value)
    end
    return tostring(value)
end

local function record(...)
    local fields = {}
    for i = 1, select("#", ...) do
        fields[i] = field((select(i, ...)))
    end
    writer:writeln(table.concat(fields, "\t"))
end

--- Starts a new trace file.
function Trace.start()
    writer = getFileWriter(FILE, true, false)
    head = nil
end

function Trace.stop()
    if writer then
        writer:close()
        writer = nil
    end
end

function Trace.on()
    return writer ~= nil
end

--- Called every frame of a test with what heads its action queue (nil once empty); records each
--- action once it no longer heads the queue.
function Trace.observe(test, action, frame)
    if not writer or action == head then
        return
    end
    local now = getTimestampMs()
    if head then
        record("action", headTest, headMs, now, frame - headFrame, headWhat)
    end
    head, headTest, headMs, headFrame = action, test, now, frame
    headWhat = action and PZHarness.Test.describeAction(action)
end

function Trace.test(name, startMs, endMs, frames)
    if writer then
        record("test", name, startMs, endMs, frames)
    end
end

function Trace.gap(what, startMs, endMs)
    if writer then
        record("gap", what, startMs, endMs)
    end
end

--- `request` as ServerCalls sent it, `answer` as the server gave it. An undo, which names no
--- handler, goes by its kind.
function Trace.call(kind, request, answer, sentMs, answeredMs)
    if writer then
        record("call", request.test, request.id, kind, request.name or kind, sentMs, answer.arrivedMs,
            answer.startedMs, answer.finishedMs, answeredMs, getTimestampMs())
    end
end

return Trace
