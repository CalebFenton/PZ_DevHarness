-- Development only, not published. With --mp the client joins the dedicated server run-client.sh
-- started, as its admin, instead of starting the scenario; this takes it from the main menu to the
-- scenario's start with the onStart setup copied to the server (docs/multiplayer.md).

require "PZHarness/ServerCalls"
require "PZHarness/Fixtures"
local Run = require "PZHarness/Run"
local Report = require "PZHarness/Report"

local Multiplayer = {}

local CONNECT_POLL_TICKS = 15
-- How long the character may take to reach the scenario's start, whose chunks the server sends.
local START_WAIT_MS = 30000
-- How long the client may take, after the server's answers, to show the onStart perk levels again.
local SETUP_SYNC_MS = 5000

-- Joins the server once run-client.sh says it has started, with the call the server list's
-- Connect button makes. The client and the server boot at the same time, which saves the
-- client's boot from a run; connecting before the server listens would only fail.
local function connectWhenServerUp()
    -- Joining resets Lua (Core.ResetLua), which fires OnMainMenuEnter again in a client that is
    -- already joining; isClient() holds from then on.
    if isClient() then
        return
    end
    local ticks = 0
    local function poll()
        ticks = ticks + 1
        local server = ticks % CONNECT_POLL_TICKS == 0 and Run.readKeys(Run.CONNECT_FILE)
        if not server then
            return
        end
        Events.OnFETick.Remove(poll)
        print("PZHarness: joining " .. server.host .. ":" .. server.port .. " as " .. server.user)
        ConnectToServer.instance:connect(MainScreen.instance.bottomPanel, "", server.user, server.password,
            server.host, "", server.port, "", false, true, 1)
    end
    Events.OnFETick.Add(poll)
end

-- After vanilla's OnConnected, which shows a new character the spawn region list or character
-- creation: the default unemployed survivor in the default spawn region, as those screens would
-- make. CharacterCreationProfession.initWorld places it on OnInitWorld.
local function skipCharacterCreation()
    if checkSavePlayerExists() then
        return
    end
    for _, screen in pairs({ MapSpawnSelect.instance, WorldSelect.instance, MainScreen.instance.charCreationProfession }) do
        screen:setVisible(false)
    end
    MainScreen.instance.desc = SurvivorFactory.CreateSurvivor(SurvivorType.Neutral, false)
    MapSpawnSelect.instance:useDefaultSpawnRegion()
    GameWindow.doRenderEvent(false)
    forceChangeState(LoadingQueueState.new())
end

local function connectFailed(message, detail)
    print("PZHarness: joining the server failed: " .. tostring(message) .. " " .. tostring(detail or ""))
    getCore():quitToDesktop()
end

-- Whether every perk of the character is at its level in `levels` (Fixtures.perkLevels).
local function hasPerkLevels(player, levels)
    for id, level in pairs(levels) do
        local perk = Perks.FromString(id)
        if perk and perk ~= Perks.MAX and player:getPerkLevel(perk) ~= level then
            return false
        end
    end
    return true
end

--- Copies onStart's perk levels and recipes to the server's copy of the character, which crafts
--- and actions check, clears the server's sky (Fixtures.clearWeather), and calls `start` once both
--- sides have them. The server overwrites the client's perk list periodically (PlayerXpPacket), and
--- one sent before it had the levels can land after its answer, so this waits for a later sync (new
--- PerkInfo objects) to show the levels, up to SETUP_SYNC_MS. Synced recipes are only ever added,
--- so they can't regress.
function Multiplayer.copySetupToServer(start)
    local player = getSpecificPlayer(0)
    local levels = PZHarness.Fixtures.perkLevels(player)
    PZHarness.ServerCalls.callOutsideTest("PZHarness.setPerkLevels", { levels = levels })
    PZHarness.ServerCalls.callOutsideTest("PZHarness.learnRecipes", { names = PZHarness.Fixtures.knownRecipes(player) })
    PZHarness.ServerCalls.callOutsideTest("PZHarness.clearWeather", {})
    local perkList = player:getPerkList()
    local answeredMs, before
    local function onTick()
        if PZHarness.ServerCalls.busy() then
            return
        end
        if not answeredMs then
            answeredMs = getTimestampMs()
            before = not perkList:isEmpty() and perkList:get(0) or nil
        end
        local synced = before == nil or perkList:isEmpty() or perkList:get(0) ~= before
        if not (synced and hasPerkLevels(player, levels)) then
            if getTimestampMs() - answeredMs < SETUP_SYNC_MS then
                return
            end
            Report.lateFailure("PZHarness.setPerkLevels", "this client never showed the onStart perk levels again")
        end
        Events.OnTick.Remove(onTick)
        start()
    end
    Events.OnTick.Add(onTick)
end

--- Joins the server and, once the character is in the game, moves it to the scenario's `startLoc`
--- (the server places a new character in a spawn region), then calls `arrived()`. Only with --mp.
function Multiplayer.join(arrived)
    local function onGameStart()
        local scenario = debugScenarios[PZHarness.config.scenario] or {}
        local loc = scenario.startLoc
        local sinceMs, teleported = getTimestampMs(), false
        local function onTick()
            local player = getSpecificPlayer(0)
            local here = player:getCurrentSquare()
            if loc and not (here and here:getX() == loc.x and here:getY() == loc.y and here:getZ() == loc.z) then
                if not teleported then
                    PZHarness.Fixtures.teleportToMiddle(player, loc.x, loc.y, loc.z)
                    teleported = true
                end
                if getTimestampMs() - sinceMs < START_WAIT_MS then
                    return
                end
                print("PZHarness: the character didn't reach the scenario's start; the tests run where it is")
            end
            Events.OnTick.Remove(onTick)
            arrived(scenario)
        end
        Events.OnTick.Add(onTick)
    end
    Events.OnMainMenuEnter.Add(connectWhenServerUp)
    Events.OnConnected.Add(skipCharacterCreation)
    Events.OnConnectFailed.Add(connectFailed)
    Events.OnGameStart.Add(onGameStart)
end

return Multiplayer
