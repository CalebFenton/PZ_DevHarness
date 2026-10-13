-- Development only, not published. The runner's leak check between tests (PZHarness/Runner.lua):
-- a snapshot of this game's copy around the character (shared/PZHarness/Snapshot.lua), compared
-- with the one before the last test.
--
-- In multiplayer the server takes its own ("PZHarness.snapshot" in
-- server/PZHarness/ServerFixtures.lua) while this client takes its copy's, and reports what
-- changed in its copy, which is the one that counts for objects and vehicles. This client then
-- compares the two copies on every square either side saw change. What the server sent can still
-- be on its way, so only a difference, or a change of this client's own state, costs a second look
-- once that has had time to arrive, and only what is still there is reported.

require "PZHarness/Snapshot"
require "PZHarness/ServerCalls"

PZHarness = PZHarness or {}
local Leaks = {}
PZHarness.Leaks = Leaks

local SETTLE_MS = 500

-- This game's snapshot the next check compares with, and whether the server's baseline starts
-- over with the next call.
local baseline
local fresh = true

--- Forgets the baselines on both sides, so the next check only takes them, as at a run's start.
function Leaks.reset()
    baseline = nil
    fresh = true
end

local function askServer(args, onAnswer)
    PZHarness.ServerCalls.send("call", { name = "PZHarness.snapshot", test = "PZHarness.snapshot", args = args }, onAnswer)
end

local function differs(a, b)
    local Snapshot = PZHarness.Snapshot
    return Snapshot.syncSignature(a) ~= Snapshot.syncSignature(b)
end

-- The squares where the copies may differ: changed on this client and not on the server, or on
-- both but to different looks, or on the server and not here.
local function suspectSquares(snapshot, clientChanged, serverChanged)
    local serverSigs, suspects, seen = {}, {}, {}
    for i = 1, #serverChanged - 1, 2 do
        serverSigs[serverChanged[i]] = serverChanged[i + 1]
    end
    for _, key in ipairs(clientChanged) do
        seen[key] = true
        local server = serverSigs[key]
        if server == nil or differs(server, snapshot.squares[key]) then
            table.insert(suspects, key)
        end
    end
    for key, server in pairs(serverSigs) do
        local client = snapshot.squares[key]
        if not seen[key] and client and differs(server, client) then
            table.insert(suspects, key)
        end
    end
    return suspects
end

--- Starts a check around `character`'s square, `radius` squares each way on each of `levels` (z
--- levels; the character's own by default), leaving out the objects the patterns in `ignore`
--- match. Returns a function to call every tick: nil until the check is done, then
--- { leaks = { lines }, desyncs = { lines } }, both empty the first time, when there is nothing
--- yet to compare with.
function Leaks.start(character, radius, levels, ignore)
    local Snapshot = PZHarness.Snapshot
    local result = { leaks = {}, desyncs = {} }
    local phase, area, before, snapshot, answer, peek, settleUntil, ownChanges, suspects

    local function look()
        local square = character:getCurrentSquare()
        if not square then
            return result
        end
        local x, y, z = square:getX(), square:getY(), square:getZ()
        area = { x = x, y = y, z = z, radius = radius, levels = levels or { z }, ignore = ignore, copy = isClient() }
        if not isClient() then
            snapshot = Snapshot.take(area, character)
            if baseline then
                Snapshot.addLines(result.leaks, Snapshot.diff(baseline, snapshot))
            end
            baseline = snapshot
            return result
        end
        askServer({ x = x, y = y, z = z, radius = radius, levels = area.levels, ignore = ignore, fresh = fresh },
            function(reply) answer = reply end)
        before, snapshot = baseline, Snapshot.take(area, character)
        baseline = snapshot
        phase = "answer"
        return nil
    end

    -- The server's lines count as they are; this client's square changes only as suspects, and
    -- its own state (power it works out itself, what it holds) and the clock only on the server.
    local function compare()
        fresh = false
        if answer.error then
            table.insert(result.leaks, "the server's leak check failed: " .. tostring(answer.error))
            return result
        end
        for _, line in ipairs(answer.reply.leaks or {}) do
            table.insert(result.leaks, "on the server, " .. line)
        end
        if not before then
            return result
        end
        local report = Snapshot.diff(before, snapshot, { clock = false })
        ownChanges = #report.other > 0
        suspects = suspectSquares(snapshot, report.changed, answer.reply.changed or {})
        if not ownChanges and #suspects == 0 then
            return result
        end
        phase, settleUntil = "settle", getTimestampMs() + SETTLE_MS
        return nil
    end

    -- After the second look this client's own changes that remain are leaks, and the suspect
    -- squares go to the server to compare with how they look here now.
    local function lookAgain()
        if ownChanges then
            snapshot = Snapshot.take(area, character)
            baseline = snapshot
            for _, line in ipairs(Snapshot.diff(before, snapshot, { clock = false }).other) do
                table.insert(result.leaks, line)
            end
        end
        if #suspects == 0 then
            return result
        end
        askServer({ peek = suspects, ignore = ignore }, function(reply) peek = reply end)
        phase = "peek"
        return nil
    end

    local function compareSquares()
        if peek.error then
            table.insert(result.leaks, "the server's leak check failed: " .. tostring(peek.error))
            return result
        end
        local sigs = peek.reply.sigs or {}
        for i = 1, #sigs - 1, 2 do
            local key, server = sigs[i], sigs[i + 1]
            local client = Snapshot.signatureAt(key, ignore)
            -- The next check compares with how the square looks here now.
            baseline.squares[key] = client or nil
            if server and client and differs(server, client) then
                table.insert(result.desyncs, Snapshot.where(key) .. " client [" .. Snapshot.syncSignature(client)
                    .. "] server [" .. Snapshot.syncSignature(server) .. "]")
            end
        end
        return result
    end

    phase = "look"
    return function()
        if phase == "look" then
            return look()
        elseif phase == "answer" then
            return answer and compare() or nil
        elseif phase == "settle" then
            return getTimestampMs() >= settleUntil and lookAgain() or nil
        end
        return peek and compareSquares() or nil
    end
end

return Leaks
