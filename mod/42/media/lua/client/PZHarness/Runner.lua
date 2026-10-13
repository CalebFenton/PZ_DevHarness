-- Development only, not published. bin/run-client.sh loads this mod with the mod under test and
-- its dev mod, and writes <cachedir>/Lua/PZHarness.txt: the mode (empty when playing by hand), the
-- selection (TESTS prefixes, or the mod's own for its modes), whether to stay, the console mark
-- of the mode and the tests' console tag.
--
-- The dev mod calls PZHarness.register (see README.md). In a mode, the mod's debug scenario then
-- starts from the main menu (with -debug and DebugScenario.ForceLaunch=true in debug-options.ini);
-- once the world around the character has loaded, the runner runs the mod's tests ("test") or the
-- mod's handler for the mode, prints "<mark> DONE" and quits. With --test --stay the game stays
-- open and reruns the tests on request instead. run-client.sh reads those lines from console.txt.

require "ISUI/ISUIElement"

PZHarness = PZHarness or {}

-- A run starts once one square in every chunk this many squares around the character has loaded,
-- or after SETTLE_MAX_TICKS ticks.
local LOADED_RADIUS = 40
local SETTLE_MAX_TICKS = 600
-- How long a test waits for the character's square to load after the last test took it far away.
local SQUARE_WAIT_MS = 10000
-- With --stay, run-client.sh writes this file in <cachedir>/Lua to rerun the tests; the game looks
-- for it every REQUEST_POLL_TICKS ticks and quits after STAY_IDLE_MS without one.
local REQUEST_FILE = "PZHarnessRerun.txt"
local REQUEST_POLL_TICKS = 15
local STAY_IDLE_MS = 10 * 60 * 1000
-- While --stay waits, the game draws only this many frames a second, so it doesn't keep a core busy.
local IDLE_FPS = 24

-- The run run-client.sh asked for. Without the file, as in a game the script didn't start, there
-- is no mode and the tests print under a generic tag.
local function readRun()
    local run = { mode = "", selection = "", stay = false, mark = "PZHarness", tag = "PZHarness" }
    local reader = getFileReader("PZHarness.txt", false)
    if not reader then
        return run
    end
    local line = reader:readLine()
    while line do
        local key, value = string.match(line, "^(%w+)=(.*)$")
        if key == "stay" then
            run.stay = value ~= ""
        elseif key then
            run[key] = value
        end
        line = reader:readLine()
    end
    reader:close()
    return run
end

PZHarness.run = readRun()
local run = PZHarness.run

-- What the dev mod registered; see PZHarness.register.
PZHarness.config = PZHarness.config or { prefix = "", modes = {}, tests = {} }

local function startsWith(text, prefix)
    return string.sub(text, 1, #prefix) == prefix
end
PZHarness.startsWith = startsWith

-- Name prefixes from TESTS; empty runs every test of the mod.
local filters = {}

local function setFilters(tests)
    filters = {}
    for prefix in string.gmatch(tests or "", "[^,%s]+") do
        table.insert(filters, prefix)
    end
end

local function selected(name)
    if not startsWith(name, PZHarness.config.prefix) then
        return false
    end
    if #filters == 0 then
        return true
    end
    for _, prefix in ipairs(filters) do
        if startsWith(name, prefix) then
            return true
        end
    end
    return false
end

local function testNames()
    local result = {}
    for name in pairs(TimedActionTests.getTests()) do
        if selected(name) then
            table.insert(result, name)
        end
    end
    table.sort(result)
    return result
end

-- Runs the selected tests one after another with the resets of the debug menu's runner (RunTest
-- and OnTick in vanilla Tests/TimedActionsTests.lua, whose locals Lua can't reach): before each
-- test full health, an empty inventory, nothing worn or held, ISBuildMenu.cheat off and the test's
-- name said aloud; validate() once the action queue is empty; then the cheat back and the
-- character back on the square the test started on. Vanilla pauses a second after every test so
-- you can read the result; here the next test starts on the next tick, or once the character's
-- square has loaded again after a test that went far (at most SQUARE_WAIT_MS). Calls onDone() at
-- the end.
local function runTests(onDone)
    local names = testNames()
    local tests = TimedActionTests.getTests()
    print(run.tag .. " START " .. #names)
    local passed, failed, index, ticks = 0, 0, 0, 0
    local startedMs = getTimestampMs()
    local doneMs = startedMs
    -- Where the current test started, as numbers: the square object itself goes back to the pool
    -- when a test takes the character far enough for its chunk to unload, and comes back as some
    -- other square (IsoGridSquare.discard, getNew), so teleporting to its coordinates then lands
    -- somewhere else entirely.
    local current, player, start, wasCheat
    local function atStart()
        local here = player:getCurrentSquare()
        return here ~= nil and here:getX() == start.x and here:getY() == start.y and here:getZ() == start.z
    end
    local function onTick()
        ticks = ticks + 1
        if current then
            if ISTimedActionQueue.getTimedActionQueue(player).queue[1] then
                return
            end
            if not current.validate or current:validate() then
                passed = passed + 1
            else
                failed = failed + 1
            end
            current = nil
            doneMs = getTimestampMs()
            ISBuildMenu.cheat = wasCheat
            if not atStart() then
                player:teleportTo(start.x + 0.5, start.y + 0.5, start.z)
            end
            return
        end
        player = getSpecificPlayer(0)
        if not player:getCurrentSquare() and getTimestampMs() - doneMs < SQUARE_WAIT_MS then
            return
        end
        index = index + 1
        local name = names[index]
        if not name then
            Events.OnTick.Remove(onTick)
            local seconds = (getTimestampMs() - startedMs) / 1000
            print(string.format("%s TIME %.1f s, %d frames (%.0f a second)", run.tag, seconds, ticks, ticks / math.max(seconds, 0.001)))
            print(run.tag .. " DONE passed=" .. passed .. " failed=" .. failed)
            onDone()
            return
        end
        current = tests[name]
        print("TEST: " .. name)
        local here = player:getCurrentSquare()
        start = { x = here:getX(), y = here:getY(), z = here:getZ() }
        player:getBodyDamage():RestoreToFullHealth()
        player:getInventory():removeAllItems()
        player:clearWornItems()
        player:setPrimaryHandItem(nil)
        player:setSecondaryHandItem(nil)
        player:Say(name)
        wasCheat = ISBuildMenu.cheat
        ISBuildMenu.cheat = false
        current:run()
    end
    Events.OnTick.Add(onTick)
end

-- The request run-client.sh writes to REQUEST_FILE: an id, the TESTS prefixes, then the Lua files
-- to run again, in the order the mod listed them. Nil if there is none.
local function readRequest()
    local reader = getFileReader(REQUEST_FILE, false)
    if not reader then
        return nil
    end
    local request = { id = reader:readLine(), tests = reader:readLine(), files = {} }
    local line = reader:readLine()
    while line do
        table.insert(request.files, line)
        line = reader:readLine()
    end
    reader:close()
    return request
end

-- What the kept game shows on screen and prints while it waits for a request, so whoever watches
-- the window can tell an idle game from a stuck one.
local IDLE_TEXT = run.tag .. " IDLE waiting for the next --test --stay run (quits after " .. STAY_IDLE_MS / 60000 .. " minutes)"

local IdleNote = ISUIElement:derive("PZHarnessIdleNote")

function IdleNote:render()
    self:drawText(IDLE_TEXT, 0, 0, 1, 1, 0.4, 1, UIFont.Large)
end

-- Runs the tests again for every new request until STAY_IDLE_MS pass without one. reloadLuaFile
-- runs a file again but ignores its Events.*.Add calls (LuaCompiler.rewriteEvents), which suits
-- test files: they only register tests. Every test of the mod is unregistered first, so a test
-- that was renamed or deleted doesn't run again.
local function serveReruns()
    local performance = getPerformance()
    local fps, uncapped = performance:getFramerate(), performance:isFramerateUncapped()
    local note = IdleNote:new(40, 40, getCore():getScreenWidth() - 80, 40)
    note:initialise()
    local handled
    local waitingSince, ticks = getTimestampMs(), 0
    local onTick
    local function idle()
        performance:setFramerateUncapped(false)
        performance:setFramerate(IDLE_FPS)
        print(IDLE_TEXT)
        note:addToUIManager()
        waitingSince = getTimestampMs()
        Events.OnTick.Add(onTick)
    end
    onTick = function()
        ticks = ticks + 1
        if ticks % REQUEST_POLL_TICKS ~= 0 then
            return
        end
        if getTimestampMs() - waitingSince > STAY_IDLE_MS then
            Events.OnTick.Remove(onTick)
            print(run.tag .. " STAY ends: no request for " .. STAY_IDLE_MS / 60000 .. " minutes")
            getCore():quitToDesktop()
            return
        end
        local request = readRequest()
        if not request or not request.id or request.id == handled then
            return
        end
        handled = request.id
        Events.OnTick.Remove(onTick)
        note:removeFromUIManager()
        performance:setFramerate(fps)
        performance:setFramerateUncapped(uncapped)
        print(run.tag .. " RUN " .. request.id)
        local tests = TimedActionTests.getTests()
        local registered = {}
        for name in pairs(tests) do
            if startsWith(name, PZHarness.config.prefix) then
                table.insert(registered, name)
            end
        end
        for _, name in ipairs(registered) do
            tests[name] = nil
        end
        for _, file in ipairs(request.files) do
            reloadLuaFile(file)
        end
        setFilters(request.tests)
        runTests(idle)
    end
    idle()
end

local function quit()
    getCore():quitToDesktop()
end

-- What a mode handler calls when it is done.
local function done()
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

-- Runs `start` once the world around the character has loaded.
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
        setFilters(run.selection)
        runTests(run.stay and serveReruns or quit)
        return
    end
    local mode = PZHarness.config.modes[run.mode]
    if not mode then
        print("PZHarness: the dev mod registered no mode " .. run.mode)
        quit()
        return
    end
    mode.run(run.selection, done)
end

--- Called once by the dev mod, at load. `config`:
--- - `scenario`: the key of the mod's scenario in `debugScenarios`, which every mode starts.
--- - `prefix`: the name prefix of the mod's tests in TimedActionTests; --test runs those.
--- - `modes`: the mod's other modes by name, each `{ run = function(selection, done), uncapped }`.
---   `run` is called once the world has loaded, with the selection run-client.sh passed, and
---   calls `done()` when it has finished. `uncapped` draws as many frames as the machine can.
--- - `onStart(mode)`: optional, called after the scenario's own onStart in every mode.
--- - `tests`: settings of the test library, see PZHarness/TestLib.lua.
function PZHarness.register(config)
    PZHarness.config = {
        scenario = config.scenario,
        prefix = config.prefix or "",
        modes = config.modes or {},
        onStart = config.onStart,
        tests = config.tests or {},
    }
    if run.mode == "" then
        return
    end
    local scenario = debugScenarios[config.scenario]
    scenario.forceLaunch = true

    -- Single player pauses when the window loses focus, and paused games don't tick, so the run
    -- would stop whenever someone switches to another window.
    getCore():setOptionPauseOnFocusloss(false)

    -- Game time per second doesn't depend on the frame rate (FPSTracking), so more frames a second
    -- only shorten what is counted in ticks: the tests' waits for the game to apply a change, and
    -- from here on the world loading. Measured on an M3 Max, uncapped draws about 260 frames a
    -- second against 60. The option can't do it: Core.loadOptions resets uncappedFPS to false and
    -- frameRate to 60. A mode whose steps wait fixed tick counts keeps 60.
    local mode = PZHarness.config.modes[run.mode]
    if run.mode == "test" or (mode and mode.uncapped) then
        getPerformance():setFramerateUncapped(true)
    end

    local originalOnStart = scenario.onStart
    scenario.onStart = function()
        originalOnStart()
        if PZHarness.config.onStart then
            PZHarness.config.onStart(run.mode)
        end
        afterSettling(startMode)
    end
end

return PZHarness
