-- Development only, not published. The reruns of a game --stay keeps open after its test run.

require "ISUI/ISUIElement"
require "PZHarness/ServerCalls"
local Run = require "PZHarness/Run"
local Schedule = require "PZHarness/Schedule"

local Stay = {}

local run = PZHarness.run

local REQUEST_POLL_TICKS = 15
-- Long, because restarting a multiplayer game is slow.
local STAY_IDLE_MS = 30 * 60 * 1000
-- While the game waits, it draws only this many frames a second, so it doesn't keep a core busy.
local IDLE_FPS = 24

-- What the kept game shows on screen and prints while it waits for a request, so whoever watches
-- the window can tell an idle game from a stuck one.
local IDLE_TEXT = run.tag .. " IDLE waiting for the next --stay run (quits after " .. STAY_IDLE_MS / 60000 .. " minutes)"

local IdleNote = ISUIElement:derive("PZHarnessIdleNote")

function IdleNote:render()
    self:drawText(IDLE_TEXT, 0, 0, 1, 1, 0.4, 1, UIFont.Large)
end

--- Reruns the tests for every request run-client.sh writes (Run.readRequest) until STAY_IDLE_MS
--- pass without one. reloadLuaFile ignores a file's Events.*.Add calls (LuaCompiler.rewriteEvents),
--- which suits test files. The mod's tests are unregistered first so renamed or deleted ones don't
--- run again. With --mp the server loads its files again first.
function Stay.serve()
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
        local request = Run.readRequest()
        if not request or not request.id or request.id == handled then
            return
        end
        handled = request.id
        Events.OnTick.Remove(onTick)
        note:removeFromUIManager()
        performance:setFramerate(fps)
        performance:setFramerateUncapped(uncapped)
        print(run.tag .. " RUN " .. request.id)
        local function rerun()
            local tests = TimedActionTests.getTests()
            local registered = {}
            for name in pairs(tests) do
                if luautils.stringStarts(name, PZHarness.config.prefix) then
                    table.insert(registered, name)
                end
            end
            for _, name in ipairs(registered) do
                tests[name] = nil
            end
            for _, file in ipairs(request.files) do
                reloadLuaFile(file)
            end
            for key, value in pairs(request.options) do
                run[key] = value
            end
            Schedule.runTests(request.tests, idle)
        end
        if not isClient() then
            rerun()
            return
        end
        -- A failure is in the server's log as SERVER FAIL, which fails the run.
        PZHarness.ServerCalls.send("reload", { run = request.id, files = request.serverFiles }, rerun)
    end
    idle()
end

return Stay
