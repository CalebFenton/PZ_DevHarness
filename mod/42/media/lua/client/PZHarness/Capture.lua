-- Development only, not published. Support for screenshot modes (docs/adopting.md, "Capture
-- modes"): steps run one per tick with waits between them, and UI shots are taken on a black and
-- a white backdrop so lib/capture.py can recover per-pixel transparency. Named regions go to
-- <cachedir>/Lua/<mark>.json for lib/capture.py to crop, with the item and recipe names a mod's
-- pages are laid out from (Capture.newCatalog) and the icons they name (Run:addIconSheet).

require "ISUI/ISPanel"
require "PZHarness/TestLib"

PZHarness = PZHarness or {}
local Capture = {}
PZHarness.Capture = Capture

-- Frames, or UI drawings, for a change to reach the screen, where the screenshot reads it.
Capture.DRAW_FRAMES = 10
-- How long a step's wait may poll before the run logs it and goes on; runSteps counts these.
local WAIT_MAX_MS = 10000

-- JSON

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

-- Steps

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

-- Regions

--- A named part of a shot, in UI units, which lib/capture.py crops into captures/<name>.png.
function Capture.region(name, x, y, w, h)
    return { name = name, x = math.floor(x), y = math.floor(y), w = math.floor(w), h = math.floor(h) }
end

--- The region an element covers on the screen.
function Capture.elementRegion(name, element)
    return Capture.region(name, element:getAbsoluteX(), element:getAbsoluteY(), element:getWidth(), element:getHeight())
end

-- A run

local Run = {}
Run.__index = Run

--- A run of steps that logs under `mark`, with the shots it names and their groups, so
--- lib/capture.py replaces only the captures of groups this run shot. Shot files start with
--- `prefix` (mode name and "_"), which run-client.sh clears before a run of the mode.
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

-- Icon sheets

local IconSheet = ISPanel:derive("PZHarnessCaptureIconSheet")

function IconSheet:render()
    for _, icon in ipairs(self.icons) do
        self:drawTextureScaled(icon.texture, icon.x, icon.y, icon.w, icon.h, 1, 1, 1, 1)
    end
end

-- Space between icons on a sheet, so that no crop takes in a neighbour's edge.
local ICON_GAP = 32

--- Adds the steps that lay `icons` out on a backdrop at their own size and shoot them matted as
--- `name`, each icon its own region. `icons` is a list of { name, texture }, such as
--- Catalog:iconList(), or a function returning one when the step runs.
function Run:addIconSheet(name, icons)
    local sheet
    self:add(function()
        local backdrop = self:newBackdrop()
        sheet = IconSheet:new(100, 100, getCore():getScreenWidth() - 200, getCore():getScreenHeight() - 200)
        sheet:noBackground()
        sheet.icons = {}
        local x, y, rowHeight = 0, 0, 0
        for _, icon in ipairs(type(icons) == "function" and icons() or icons) do
            local w, h = icon.texture:getWidthOrig(), icon.texture:getHeightOrig()
            if x + w > sheet.width then
                x, y, rowHeight = 0, y + rowHeight + ICON_GAP, 0
            end
            table.insert(sheet.icons, { name = icon.name, texture = icon.texture, x = x, y = y, w = w, h = h })
            x = x + w + ICON_GAP
            rowHeight = math.max(rowHeight, h)
        end
        backdrop:addChild(sheet)
        return Capture.drawn(Capture.DRAW_FRAMES)
    end)
    self:addMatted(name, function()
        local regions = {}
        for _, icon in ipairs(sheet.icons) do
            table.insert(regions, Capture.region(icon.name, sheet:getAbsoluteX() + icon.x, sheet:getAbsoluteY() + icon.y,
                icon.w, icon.h))
        end
        return regions
    end)
    self:removeBackdrop()
end

-- Items and recipes

--- The icon the crafting window draws for `fullType`: the script's, which for a moveable is not
--- the tile the inventory shows, or else the item's own.
function Capture.iconTexture(fullType)
    local icon = getScriptManager():getItem(fullType):getIcon()
    return icon and getTexture("Item_" .. icon) or instanceItem(fullType):getTex()
end

local Catalog = {}
Catalog.__index = Catalog

--- The item and recipe entries a mod's pages are laid out from, in the game's language, and the
--- icons they name, for Run:addIconSheet. `opts.prefer`: the full types an input that takes any
--- item with a tag shows, as PZHarness.Test.inputItem picks; `opts.fluidContainers`: by fluid type,
--- the container a line that takes or fills any fluid container shows; `opts.literature`: the
--- full types of the items that teach recipes.
function Capture.newCatalog(opts)
    opts = opts or {}
    return setmetatable({ prefer = opts.prefer or {}, fluidContainers = opts.fluidContainers or {},
        literature = opts.literature or {}, icons = {}, order = {} }, Catalog)
end

-- Registers `texture` for the icon sheet as `key`, named `name`, once.
function Catalog:addIcon(key, name, texture)
    if not self.icons[key] then
        self.icons[key] = { name = name, texture = texture }
        table.insert(self.order, key)
    end
    return key
end

--- An item entry: { icon, name, fullType, count }, its icon `icon_<Module>_<Type>`.
function Catalog:item(fullType, count)
    local key = "icon_" .. string.gsub(fullType, "%.", "_")
    if not self.icons[key] then
        self:addIcon(key, instanceItem(fullType):getDisplayName(), Capture.iconTexture(fullType))
    end
    return { icon = key, name = self.icons[key].name, fullType = fullType, count = count }
end

--- An item entry for each of `fullTypes`, in order.
function Catalog:items(fullTypes)
    local items = {}
    for _, fullType in ipairs(fullTypes) do
        table.insert(items, self:item(fullType))
    end
    return items
end

--- What the build menu's recipe `name` builds (an entity of module Base): { icon, name }, its icon
--- `icon_build_<name>` the build menu's.
function Catalog:build(name)
    local key = "icon_build_" .. name
    if not self.icons[key] then
        local script = getScriptManager():getGameEntityScript("Base." .. name)
        local component = script:getComponentScriptFor(ComponentType.CraftRecipe)
        self:addIcon(key, getRecipeDisplayName(name), component:getIconTexture())
    end
    return { icon = key, name = self.icons[key].name }
end

-- The fluid of a recipe line's fluid part and the litres it takes or gives: { name, litres }, and
-- the fluid's type.
local function fluidEntry(fluid, litres)
    return { name = fluid:getTranslatedName(), litres = litres }, fluid:getFluidTypeString()
end

-- One input line: the items it names (every one, as alternatives, with what each takes), or for a
-- tag or any item the preferred one. A line that takes a fluid from a container (`fluid`), or
-- pours one into an empty container the player keeps (`fills`), says which and how much; `tag`
-- marks a line whose item only stands for the many it takes, and `uses` one that counts a
-- drainable's uses rather than items.
function Catalog:input(input)
    local names, counts = {}, {}
    local listed = input:getItems()
    for i = 0, listed:size() - 1 do
        local fullType = listed:get(i)
        if not string.find(fullType, "%.") then
            fullType = "Base." .. fullType
        end
        table.insert(names, fullType)
        table.insert(counts, input:getIntAmount(i))
    end
    local entry = { items = {}, count = input:getIntAmount(), keep = input:isKeep(), tag = #names == 0 }
    local fluidType
    if input:hasConsumeFromItem() then
        local consume = input:getConsumeFromItemScript()
        local fluids = consume:getPossibleInputFluids()
        if fluids:size() > 0 then
            entry.fluid, fluidType = fluidEntry(fluids:get(0), consume:getAmount())
        end
    elseif input:hasCreateToItem() then
        local create = input:getCreateToItemScript()
        if create:getFluid() then
            entry.fills, fluidType = fluidEntry(create:getFluid(), create:getAmount())
        end
    end
    if #names == 0 then
        names = { self.fluidContainers[fluidType] or PZHarness.Test.inputItem(input, self.prefer):getFullName() }
        counts = { entry.count }
    end
    local first = getScriptManager():getItem(names[1])
    -- A drainable input counts uses unless it says ItemCount.
    entry.uses = first:isItemType(ItemType.DRAINABLE) and not input:isItemCount()
    for i, fullType in ipairs(names) do
        table.insert(entry.items, self:item(fullType, counts[i]))
    end
    return entry
end

local function skillList(count, get)
    local skills = {}
    for i = 0, count - 1 do
        local skill = get(i)
        table.insert(skills, { name = skill:getPerk():getName(), level = skill:getLevel() })
    end
    return skills
end

-- The names of the literature that teaches the recipe `name`.
function Catalog:teaching(name)
    local found = {}
    for _, fullType in ipairs(self.literature) do
        local learned = getScriptManager():getItem(fullType):getLearnedRecipes()
        for i = 0, (learned and learned:size() or 0) - 1 do
            if learned:get(i) == name then
                table.insert(found, getItemNameFromFullType(fullType))
            end
        end
    end
    return found
end

-- The names of the items that research each recipe, by recipe: the ones whose script lists it
-- among its ResearchableRecipes, which the game extends with every recipe's own outputs
-- (OutputMapper). Built once, since it walks every item script.
local researchers

local function researchedBy(name)
    if not researchers then
        researchers = {}
        local scripts = getScriptManager():getAllItems()
        for i = 0, scripts:size() - 1 do
            local script = scripts:get(i)
            local recipes = script:hasResearchableRecipes() and script:getResearchableRecipes()
            for j = 0, (recipes and recipes:size() or 0) - 1 do
                local recipe = recipes:get(j)
                researchers[recipe] = researchers[recipe] or {}
                table.insert(researchers[recipe], getItemNameFromFullType(script:getFullName()))
            end
        end
        for _, names in pairs(researchers) do
            table.sort(names)
        end
    end
    return researchers[name] or {}
end

--- The recipe `name`, a craftRecipe or, with `build`, the build menu's recipe of an entity: { id,
--- name, skills, learn = { needed, magazines, auto, autoAll, research }, inputs, outputs, build }.
function Catalog:recipe(name, build)
    local recipe = getScriptManager():getCraftRecipe(name)
    local entry = {
        id = name,
        name = getRecipeDisplayName(name),
        skills = skillList(recipe:getRequiredSkillCount(), function(i) return recipe:getRequiredSkill(i) end),
        learn = {
            needed = recipe:needToBeLearn(),
            magazines = self:teaching(name),
            auto = skillList(recipe:getAutoLearnAnySkillCount(), function(i) return recipe:getAutoLearnAnySkill(i) end),
            autoAll = skillList(recipe:getAutoLearnAllSkillCount(), function(i) return recipe:getAutoLearnAllSkill(i) end),
            research = researchedBy(name),
        },
        inputs = {},
        outputs = {},
        build = build and self:build(name) or nil,
    }
    local inputs = recipe:getInputs()
    for i = 0, inputs:size() - 1 do
        table.insert(entry.inputs, self:input(inputs:get(i)))
    end
    local outputs = recipe:getOutputs()
    for i = 0, outputs:size() - 1 do
        local output = outputs:get(i)
        table.insert(entry.outputs, self:item(output:getPossibleResultItems():get(0):getFullName(), output:getIntAmount()))
    end
    return entry
end

--- Every recipe whose name starts with `prefix` (the `recipePrefix` test setting by default): the
--- craftRecipes, then the build menu's.
function Catalog:recipes(prefix)
    local recipes = {}
    for _, name in ipairs(PZHarness.Test.recipeNames(prefix)) do
        table.insert(recipes, self:recipe(name))
    end
    for _, name in ipairs(PZHarness.Test.buildRecipeNames(prefix)) do
        table.insert(recipes, self:recipe(name, true))
    end
    return recipes
end

--- Every icon the entries made so far name, in the order they were first named: { name, texture }.
function Catalog:iconList()
    local list = {}
    for _, key in ipairs(self.order) do
        table.insert(list, { name = key, texture = self.icons[key].texture })
    end
    return list
end

return Capture
