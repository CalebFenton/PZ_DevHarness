-- Development only, not published. bin/run-client.sh loads this mod alongside the mod under test
-- and its dev mod, and describes the run in <cachedir>/Lua/PZHarness.txt (Run.lua). In a mode,
-- the mod's debug scenario starts from the main menu, or with --mp the client joins the dedicated
-- server; once the world has loaded the runner runs the tests or the mode's handler, prints
-- "<mark> DONE", which run-client.sh waits for in console.txt, and quits.

require "PZHarness/Run"
require "PZHarness/Fixtures"
local Schedule = require "PZHarness/Schedule"
local Stay = require "PZHarness/Stay"
local Multiplayer = require "PZHarness/Multiplayer"

local run = PZHarness.run

-- A run starts once one square in every chunk this many squares around the character has loaded,
-- or after SETTLE_MAX_TICKS ticks.
local LOADED_RADIUS = 40
local SETTLE_MAX_TICKS = 600
-- The highest uiRenderFPS the option takes (Core.optionUiRenderFps).
local FAST_UI_FPS = 120

local function quit()
    getCore():quitToDesktop()
end

-- The player's uiRenderFPS while a capture mode runs. done() puts it back before the game quits,
-- which saves the options, so options.ini never keeps the mode's rate.
local savedUIFps

local function done()
    if savedUIFps then
        getCore():setOptionUIRenderFPS(savedUIFps)
        savedUIFps = nil
    end
    print(run.mark .. " DONE")
    quit()
end

local function worldLoaded()
    local square = getSpecificPlayer(0):getCurrentSquare()
    if not square then
        return false
    end
    local cell, x, y = getCell(), square:getX(), square:getY()
    for dx = -LOADED_RADIUS, LOADED_RADIUS, 8 do
        for dy = -LOADED_RADIUS, LOADED_RADIUS, 8 do
            if not cell:getGridSquare(x + dx, y + dy, 0) then
                return false
            end
        end
    end
    return true
end

local function afterSettling(start)
    local ticks = 0
    local function onTick()
        ticks = ticks + 1
        if worldLoaded() or ticks >= SETTLE_MAX_TICKS then
            Events.OnTick.Remove(onTick)
            print("PZHarness: starting after " .. ticks .. " ticks")
            start()
        end
    end
    Events.OnTick.Add(onTick)
end

local function startMode()
    if run.mode == "test" then
        -- Tests run under a clear sky, which a new world's weather would otherwise vary from run to
        -- run; a multiplayer client gets the server's (Multiplayer.copySetupToServer).
        if not isClient() then
            PZHarness.Fixtures.clearWeather()
        end
        Schedule.runTests(run.selection, run.stay and Stay.serve or quit)
        return
    end
    local mode = PZHarness.config.modes[run.mode]
    if not mode then
        print("PZHarness: the dev mod registered no mode " .. run.mode)
        quit()
        return
    end
    if mode.capture then
        PZHarness.Fixtures.clearWeather()
        -- The UI draws at its own rate (Core.StartFrameUI) and the frames in between show its last
        -- drawing, so a mode that waits for the UI to draw waits less at the highest rate.
        savedUIFps = getCore():getOptionUIRenderFPS()
        getCore():setOptionUIRenderFPS(FAST_UI_FPS)
    end
    mode.run(run.selection, done)
end

if run.mp then
    Multiplayer.join(function(scenario)
        afterSettling(function()
            if scenario.onStart then
                scenario.onStart()
            end
            if PZHarness.config.onStart then
                PZHarness.config.onStart(run.mode)
            end
            Multiplayer.copySetupToServer(startMode)
        end)
    end)
end

--- Gives `scenario`, a debugScenarios entry, a new save that records the active mods, which
--- DebugScenarios doesn't do (see MainScreen.resetLuaIfNeeded), and has no zombies; with `quiet`
--- (run-client.sh's "Key=value,Table.Key=value,..." for a --test world: QUIET_WORLD and
--- TEST_SANDBOX) those options too, "Table.Key" in SandboxVars[Table]. The scenario's own
--- setSandbox runs after, so the mod's settings win.
function PZHarness.wrapSetSandbox(scenario, quiet)
    local originalSetSandbox = scenario.setSandbox
    scenario.setSandbox = function()
        ActiveMods.getById("currentGame"):copyFrom(ActiveMods.getById("default"))
        SandboxVars.Zombies = 6 -- none
        for key, value in string.gmatch(quiet or "", "([%w_.]+)=([^,]+)") do
            local options, name = SandboxVars, key
            local group, option = string.match(key, "^([%w_]+)%.([%w_]+)$")
            if group then
                SandboxVars[group] = SandboxVars[group] or {}
                options, name = SandboxVars[group], option
            end
            if value == "true" or value == "false" then
                options[name] = value == "true"
            else
                options[name] = tonumber(value) or value
            end
        end
        if originalSetSandbox then
            originalSetSandbox()
        end
    end
end

--- Called once by the dev mod, at load. `config`:
--- - `scenario`: the key of the mod's scenario in `debugScenarios`, which every mode starts. Its
---   world gets the active mods and no zombies from the harness.
--- - `prefix`: the name prefix of the mod's tests in TimedActionTests; --test runs those.
--- - `modes`: the mod's other modes by name, each `{ run = function(selection, done), capture }`.
---   `run` is called once the world has loaded, with the selection run-client.sh passed, and
---   calls `done()` when it has finished. `capture` is for a mode that waits on the lighting, the
---   zoom and the UI rather than on frame counts: it draws as many frames as the machine can,
---   clears the sky at once and keeps it clear, and draws the UI at its highest rate until
---   `done()`, which puts the option back.
--- - `onStart(mode)`: optional, called after the scenario's own onStart in every mode.
--- The test library's settings come from PZHarness.registerTests (shared/PZHarness/Fixtures.lua).
--- With --mp no scenario starts: the client joins the server, the runner takes the character to
--- the scenario's `startLoc` and calls its onStart and the mod's (Multiplayer.lua).
function PZHarness.register(config)
    PZHarness.config = {
        scenario = config.scenario,
        prefix = config.prefix or "",
        modes = config.modes or {},
        onStart = config.onStart,
    }
    local scenario = debugScenarios[config.scenario]
    if run.mode == "" then
        PZHarness.wrapSetSandbox(scenario, "")
        return
    end
    -- run-client.sh times the game's boot up to the first of these; --mp prints one again after
    -- joining resets the Lua.
    print("PZHarness: the dev mod registered for " .. run.mode)

    -- Single player pauses when the window loses focus, and paused games don't tick, so the run
    -- would stop whenever someone switches to another window.
    getCore():setOptionPauseOnFocusloss(false)

    -- Game time per second doesn't depend on frame rate, so uncapped frames only shorten what's
    -- counted in ticks (test waits, world loading). The option can't do it: Core.loadOptions resets
    -- uncappedFPS and frameRate. Every mode loads uncapped; a mode whose steps wait fixed tick
    -- counts recaps when the scenario starts.
    local mode = PZHarness.config.modes[run.mode]
    local uncapped = run.mode == "test" or (mode and mode.capture)
    getPerformance():setFramerateUncapped(true)
    if run.mp then
        return
    end

    scenario.forceLaunch = true
    PZHarness.wrapSetSandbox(scenario, run.mode == "test" and run.quiet or "")

    local originalOnStart = scenario.onStart
    scenario.onStart = function()
        if not uncapped then
            getPerformance():setFramerateUncapped(false)
        end
        originalOnStart()
        if PZHarness.config.onStart then
            PZHarness.config.onStart(run.mode)
        end
        afterSettling(startMode)
    end
end

return PZHarness
