-- Development only, not published. The runner's leak check between tests (PZHarness/Runner.lua):
-- a snapshot of this game's copy around the character (shared/PZHarness/Snapshot.lua), compared
-- with the one before the last test.
--
-- In multiplayer the server takes its own ("PZHarness.snapshot" in
-- server/PZHarness/ServerFixtures.lua) while this client takes its copy's, and reports what
-- changed in its copy, which is the one that counts for objects and vehicles. This client then
-- compares the two copies on every square either side saw change. What the server sent can still
-- be on its way, so a difference, or a change of this client's own state, gets looked at again
-- every few ticks until this client has caught up with what the server reported, up to a limit,
-- and only what is still there then is reported.

require "PZHarness/Snapshot"
require "PZHarness/ServerCalls"

PZHarness = PZHarness or {}
local Leaks = {}
PZHarness.Leaks = Leaks

-- The longest a check waits for the server's updates to arrive, and how often it looks meanwhile.
local SETTLE_MS = 500
local SETTLE_POLL_MS = 50

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
-- both but to different looks, or on the server and not here. Also returns, for each, the look
-- this client should catch up to: the server's, or for a square the server saw no change on, the
-- look from before.
local function suspectSquares(before, snapshot, clientChanged, serverChanged)
    local serverSigs, suspects, expected, seen = {}, {}, {}, {}
    for i = 1, #serverChanged - 1, 2 do
        serverSigs[serverChanged[i]] = serverChanged[i + 1]
    end
    for _, key in ipairs(clientChanged) do
        seen[key] = true
        local server = serverSigs[key]
        if server == nil or differs(server, snapshot.squares[key]) then
            table.insert(suspects, key)
            expected[key] = server or before.squares[key]
        end
    end
    for key, server in pairs(serverSigs) do
        local client = snapshot.squares[key]
        if not seen[key] and client and differs(server, client) then
            table.insert(suspects, key)
            expected[key] = server
        end
    end
    return suspects, expected
end

--- Starts a check around `character`'s square, `radius` squares each way on each of `levels` (z
--- levels; the character's own by default), leaving out the objects the patterns in `ignore`
--- match. In multiplayer the server's half is asked for at once around `at` ({ x, y, z }, the
--- square the character will stand on), so the request goes out with whatever else the server
--- has to do first; without `at`, once the check first looks. Returns a function to call every
--- tick from when this client's copy is ready to be looked at: nil until the check is done, then
--- { leaks = { lines }, desyncs = { lines }, waitedFull }, both lists empty the first time, when
--- there is nothing yet to compare with, and when the character's square isn't loaded;
--- `waitedFull` is true when this client never caught up with the server before the limit.
function Leaks.start(character, at, radius, levels, ignore)
    local Snapshot = PZHarness.Snapshot
    local result = { leaks = {}, desyncs = {}, waitedFull = false }
    local phase, area, before, snapshot, answer, peek, settleUntil, nextPollMs, ownChanges, suspects, expected
    local asked = false

    local function ask(x, y, z)
        asked = true
        askServer({ x = x, y = y, z = z, radius = radius, levels = levels or { z }, ignore = ignore, fresh = fresh },
            function(reply) answer = reply end)
    end
    if isClient() and at then
        ask(at.x, at.y, at.z)
    end

    local function look()
        local square = character:getCurrentSquare()
        if not square then
            -- Unchecked, this test's leftovers would be blamed on the next test, so the next
            -- check only takes new baselines, on both sides.
            Leaks.reset()
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
        if not asked then
            ask(x, y, z)
        end
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
        suspects, expected = suspectSquares(before, snapshot, report.changed, answer.reply.changed or {})
        if not ownChanges and #suspects == 0 then
            return result
        end
        local now = getTimestampMs()
        phase, settleUntil, nextPollMs = "settle", now + SETTLE_MS, now
        return nil
    end

    -- Whether this client has caught up: its own state is back to how it was before the test, and
    -- each suspect square looks the way it should (suspectSquares). What has caught up leaves the
    -- check, and the next check compares with how it looks now.
    local function caughtUp()
        if ownChanges then
            snapshot = Snapshot.take(area, character)
            baseline = snapshot
            if #Snapshot.diff(before, snapshot, { clock = false }).other > 0 then
                return false
            end
            ownChanges = false
        end
        local open = {}
        for _, key in ipairs(suspects) do
            local client = Snapshot.signatureAt(key, ignore)
            if client and expected[key] and not differs(expected[key], client) then
                baseline.squares[key] = client
            else
                table.insert(open, key)
            end
        end
        suspects = open
        return #suspects == 0
    end

    -- Once the limit has passed, this client's own changes that remain are leaks, and the suspect
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

    local function settle()
        local now = getTimestampMs()
        if now >= settleUntil then
            result.waitedFull = true
            return lookAgain()
        end
        if now < nextPollMs then
            return nil
        end
        nextPollMs = now + SETTLE_POLL_MS
        return caughtUp() and result or nil
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
            return settle()
        end
        return peek and compareSquares() or nil
    end
end

return Leaks
