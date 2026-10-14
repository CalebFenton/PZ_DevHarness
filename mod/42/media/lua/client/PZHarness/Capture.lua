-- Development only, not published. What a mode that takes screenshots needs, such as a mod's
-- --promo or --art (docs/adopting.md, "Capture modes"): steps run one per tick with waits between
-- them, waits for the UI to draw and the zoom to settle, and shots of UI on a backdrop taken on
-- black and on white, so that the harness's lib/capture.py can recover how transparent each pixel
-- is. A run that names its shots' regions writes them to <cachedir>/Lua/<mark>.json for
-- lib/capture.py to crop.

require "ISUI/ISPanel"

PZHarness = PZHarness or {}
local Capture = {}
PZHarness.Capture = Capture

-- Frames, or UI drawings, for a change to reach the screen, where the screenshot reads it.
Capture.DRAW_FRAMES = 10
-- How long a step's wait may poll before the run logs it and goes on; runSteps counts these.
local WAIT_MAX_MS = 10000

-- JSON -------------------------------------------------------------------------------------------

-- A table is an array when its keys are exactly 1 to #value, so a sparse table or one with other
-- keys too is an object; Kahlua has no next(), so the keys are counted with pairs(). An empty
-- table is an array.
local function isArray(value)
    local count = 0
    for _ in pairs(value) do
        count = count + 1
    end
    return count == #value
end

local function encode(value, out)
    local kind = type(value)
    if kind == "table" then
        if isArray(value) then
            table.insert(out, "[")
            for i, element in ipairs(value) do
                if i > 1 then
                    table.insert(out, ",")
                end
                encode(element, out)
            end
            table.insert(out, "]")
        else
            local keys = {}
            for key in pairs(value) do
                table.insert(keys, key)
            end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            table.insert(out, "{")
            for i, key in ipairs(keys) do
                if i > 1 then
                    table.insert(out, ",")
                end
                encode(tostring(key), out)
                table.insert(out, ":")
                encode(value[key], out)
            end
            table.insert(out, "}")
        end
    elseif kind == "string" then
        local escaped = string.gsub(value, '[%c"\\]', function(c)
            return string.format("\\u%04x", string.byte(c))
        end)
        table.insert(out, '"' .. escaped .. '"')
    elseif kind == "number" then
        -- JSON has no NaN or infinity, so a figure that came out as one has to be fixed at its source.
        if value ~= value or value == math.huge or value == -math.huge then
            error("PZHarness.Capture: non-finite number in the JSON")
        end
        table.insert(out, tostring(value))
    elseif kind == "boolean" then
        table.insert(out, tostring(value))
    else
        table.insert(out, "null")
    end
end

--- Writes `value` as JSON to <cachedir>/Lua/<fileName>.
function Capture.writeJson(fileName, value)
    local out = {}
    encode(value, out)
    local writer = getFileWriter(fileName, true, false)
    writer:write(table.concat(out))
    writer:close()
end

-- Steps ------------------------------------------------------------------------------------------

--- Runs each step on its own tick, then waits before the next: as many ticks as the step returns,
--- or, if it returns a function, until that function returns true. A function polled for longer
--- than WAIT_MAX_MS is logged under `mark` and given up. Then calls onDone with how many waits
--- gave up, since a shot after one shows a scene that never settled.
function Capture.runSteps(steps, onDone, mark)
    local index, wait, poll, pollStart, gaveUp = 1, 0, nil, 0, 0
    local function onTick()
        if poll then
            if poll() then
                poll = nil
            elseif getTimestampMs() - pollStart > WAIT_MAX_MS then
                print(string.format("%s WAIT gave up on step %d after %d ms", mark, index - 1, WAIT_MAX_MS))
                poll = nil
                gaveUp = gaveUp + 1
            end
            return
        end
        if wait > 0 then
            wait = wait - 1
            return
        end
        local step = steps[index]
        if not step then
            Events.OnTick.Remove(onTick)
            onDone(gaveUp)
            return
        end
        index = index + 1
        local result = step()
        if type(result) == "function" then
            poll, pollStart = result, getTimestampMs()
        else
            wait = result or 0
        end
    end
    Events.OnTick.Add(onTick)
end

-- The UI draws at its own rate (Core.StartFrameUI, the uiRenderFPS option) and the frames in
-- between show its last drawing, so at an uncapped frame rate a count of frames can pass with no
-- UI drawn at all. Waits on the UI count its drawings instead.
local uiDraws = 0
Events.OnPostUIDraw.Add(function()
    uiDraws = uiDraws + 1
end)

--- A runSteps wait until the UI has drawn `count` more times.
function Capture.drawn(count)
    local start = uiDraws
    return function()
        return uiDraws - start >= count
    end
end

--- A runSteps wait until the zoom stops changing, which eases towards its target every frame.
function Capture.zoomSettled()
    local last
    return function()
        local zoom = getCore():getZoom(0)
        local settled = zoom == last
        last = zoom
        return settled
    end
end

--- Saves a full screenshot as <cachedir>/Screenshots/<file>.png and logs it under `mark`. The game
--- writes the file before the call returns (Core.TakeFullScreenshot), so no step waits after a
--- shot.
function Capture.screenshot(mark, file)
    getCore():TakeFullScreenshot(file .. ".png")
    print(mark .. " saved " .. file .. ".png")
end

--- The names in a comma-separated selection, in its order.
function Capture.names(selection)
    local names = {}
    for name in string.gmatch(selection or "", "[^,%s]+") do
        table.insert(names, name)
    end
    return names
end

-- Regions ----------------------------------------------------------------------------------------

--- A named part of a shot, in UI units, which lib/capture.py crops into captures/<name>.png.
function Capture.region(name, x, y, w, h)
    return { name = name, x = math.floor(x), y = math.floor(y), w = math.floor(w), h = math.floor(h) }
end

--- The region an element covers on the screen.
function Capture.elementRegion(name, element)
    return Capture.region(name, element:getAbsoluteX(), element:getAbsoluteY(), element:getWidth(), element:getHeight())
end

-- A run ------------------------------------------------------------------------------------------

local Run = {}
Run.__index = Run

--- A run of steps that logs under `mark`: its `steps`, the shots it names, and the groups they
--- come in, for lib/capture.py to replace only the captures of the groups a run shot. Its shots'
--- files start with `prefix`, the mode's name and "_", since run-client.sh clears those before
--- a run of the mode.
function Capture.new(mark)
    return setmetatable({ mark = mark, prefix = PZHarness.run.mode .. "_", steps = {}, shots = {}, groups = {},
        tinted = {} }, Run)
end

function Run:add(step)
    table.insert(self.steps, step)
end

--- Starts group `name`: the shots added from now on belong to it.
function Run:group(name)
    self.current = name
    table.insert(self.groups, name)
end

function Run:screenshot(file)
    Capture.screenshot(self.mark, file)
end

--- Logs why the run can't go on and quits without "<mark> DONE", which run-client.sh reports as a
--- failed run.
function Run:fail(reason)
    print(self.mark .. " FAIL: " .. reason)
    getCore():quitToDesktop()
end

--- From a step: covers the screen with a backdrop, which the matted shots turn black and white,
--- and returns it. The shot's elements go on it.
function Run:newBackdrop()
    local backdrop = ISPanel:new(0, 0, getCore():getScreenWidth(), getCore():getScreenHeight())
    backdrop:initialise()
    backdrop:addToUIManager()
    backdrop:setVisible(true)
    self.tinted = { backdrop }
    return backdrop
end

--- From a step: has `element`, such as a 3D scene over the backdrop, take the backdrop's colour
--- too.
function Run:tint(element)
    table.insert(self.tinted, element)
end

--- Adds a step that takes the backdrop away.
function Run:removeBackdrop()
    self:add(function()
        self.tinted[1]:removeFromUIManager()
        return 1
    end)
end

-- Every tinted element, the backdrop first, takes the backdrop colour, and the UI draws it.
local function setLevel(run, level)
    for _, element in ipairs(run.tinted) do
        element.backgroundColor = { r = level, g = level, b = level, a = 1 }
    end
    return Capture.drawn(Capture.DRAW_FRAMES)
end

--- Adds the steps that shoot the backdrop's contents on black (<prefix><name>_k.png) and on
--- white (<prefix><name>_w.png). regions() runs once the shot is laid out.
function Run:addMatted(name, regions)
    local group, file = self.current, self.prefix .. name
    self:add(function()
        return setLevel(self, 0)
    end)
    self:add(function()
        self:screenshot(file .. "_k")
        return setLevel(self, 1)
    end)
    self:add(function()
        self:screenshot(file .. "_w")
        table.insert(self.shots, { file = file, group = group, matte = true, regions = regions() })
    end)
end

--- Adds the steps that shoot the screen as it is (<prefix><name>.png), such as the world.
function Run:addOpaque(name, regions)
    local group, file = self.current, self.prefix .. name
    self:add(function()
        return Capture.DRAW_FRAMES
    end)
    self:add(function()
        self:screenshot(file)
        table.insert(self.shots, { file = file, group = group, matte = false, regions = regions() })
    end)
end

--- Runs the steps, then, unless a wait gave up, writes <mark>.json, `data` with the screen's size,
--- the shots and the groups added, and calls done(). With `data` nil it writes nothing.
function Run:run(data, done)
    Capture.runSteps(self.steps, function(gaveUp)
        if gaveUp > 0 then
            -- The captures already made stay, rather than being replaced by shots of a scene that
            -- never settled.
            self:fail(gaveUp .. " waits gave up")
            return
        end
        if data then
            data.screen = { w = getCore():getScreenWidth(), h = getCore():getScreenHeight() }
            data.shots = self.shots
            data.groups = self.groups
            Capture.writeJson(self.mark .. ".json", data)
        end
        done()
    end, self.mark)
end

return Capture
