require "PZHarness/TestLib"
require "ISUI/ISContextMenu"
require "ISUI/ISWorldObjectContextMenu"
require "ISUI/ISInventoryPaneContextMenu"

-- Context-menu readers for tests: build the menu a right-click builds, find an option in it, read
-- what it shows and choose it as a click does. A test reads a menu inside one step and hides it
-- again (hideAndChildren) before the step ends, so no menu stays open into the next test.
--
-- Every submenu of a context menu belongs to the player's root menu, so getSubMenu answers on any
-- menu of the tree and a search needs no root passed down.
local T = PZHarness.Test

-- Building menus ------------------------------------------------------------------------------

--- A fresh, empty context menu, for a mod's own option builder to fill.
function T.newContext()
    return ISContextMenu.get(0, 0, 0)
end

--- The right-click menu vanilla builds for `object` in the world, as the character would open it,
--- or nil.
function T.worldMenu(object)
    local context = ISWorldObjectContextMenu.createMenu(0, { object }, 0, 0)
    return type(context) == "table" and context or nil
end

--- The right-click menu vanilla builds for `item` in the inventory, or nil.
function T.inventoryMenu(item)
    local context = ISInventoryPaneContextMenu.createMenu(0, true, { item }, 0, 0)
    return type(context) == "table" and context or nil
end

--- The submenu `option` opens, or nil.
function T.subMenu(menu, option)
    return option and option.subOption and menu:getSubMenu(option.subOption) or nil
end

--- The submenu labelled `label` in vanilla's world menu for `object`, and that menu, to hide once
--- read; nil for either missing.
function T.worldSubmenu(object, label)
    local context = T.worldMenu(object)
    if not context then
        return nil, nil
    end
    return T.subMenu(context, context:getOptionFromName(label)), context
end

-- Finding options -----------------------------------------------------------------------------

--- The option named `name` at the top level of `menu`, or nil: a submenu's same-named option
--- doesn't count.
function T.optionNamed(menu, name)
    return menu and menu.getOptionFromName and menu:getOptionFromName(name) or nil
end

--- The names of the options at the top level of `menu`, in order; empty without a menu.
function T.optionNames(menu)
    local names = {}
    for _, option in ipairs(menu and menu.options or {}) do
        table.insert(names, option.name)
    end
    return names
end

--- The first option in `menu` or any submenu under it, depth first, for which `matches(option)`
--- holds, or nil.
function T.findOption(menu, matches)
    for _, option in ipairs(menu and menu.options or {}) do
        if matches(option) then
            return option
        end
        local found = T.findOption(T.subMenu(menu, option), matches)
        if found then
            return found
        end
    end
    return nil
end

--- The first option named `name` in `menu` or any submenu under it (T.findOption), or nil.
function T.findNamed(menu, name)
    return T.findOption(menu, function(option) return option.name == name end)
end

--- The option in `menu` or any submenu under it that runs `handler`, or nil. A get-up option
--- (ISContextMenu.onGetUpAndThen) carries its handler as its first parameter.
function T.optionRunning(menu, handler)
    return T.findOption(menu, function(option)
        return option.onSelect == handler or option.param1 == handler
    end)
end

--- The option of the submenu named by the text of `nameKey` in `menu` (found in any submenu) for
--- which `matches(option)` holds, or nil.
function T.inSubmenu(menu, nameKey, matches)
    return T.findOption(T.subMenu(menu, T.findNamed(menu, getText(nameKey))), matches)
end

--- The option in `menu` or any submenu under it that acts on `item`, passed as its third
--- parameter, as vanilla's item menus pass it, or nil. Matched by id, since a server's sync can
--- replace this client's item objects.
function T.optionFor(menu, item)
    return T.findOption(menu, function(option)
        return instanceof(option.param3, "InventoryItem") and option.param3:getID() == item:getID()
    end)
end

--- The mechanics window's menu for the vehicle part `part`, built by vanilla's own
--- ISVehicleMechanics.doPartContextMenu on a window that has just what that function reads.
function T.partMenu(vehicle, part)
    local window = setmetatable({ chr = T.player(), playerNum = 0, vehicle = vehicle }, { __index = ISVehicleMechanics })
    window.getAbsoluteX = function() return 0 end
    window.getAbsoluteY = function() return 0 end
    window:doPartContextMenu(part, 0, 0)
    return window.context
end

-- Reading options -----------------------------------------------------------------------------

--- Whether `option` is in the menu and not greyed out.
function T.offered(option)
    return option ~= nil and not option.notAvailable
end

--- The tooltip text of `option`, or "" when it has none or there is no option, so a caller can
--- search it without a nil check.
function T.tooltipOf(option)
    return option and option.toolTip and option.toolTip.description or ""
end

--- What `option` (nil when not offered) shows: { shown, greyed, reason }, `reason` its tooltip.
function T.optionState(option)
    if not option then
        return { shown = false, greyed = false }
    end
    return { shown = true, greyed = option.notAvailable == true, reason = T.tooltipOf(option) }
end

--- The option `name` that `build(0, context, object)`, a mod's builder that fills a menu and
--- returns the menu it added to, adds to a fresh context menu, or nil; the menu is hidden again.
function T.menuOption(build, object, name)
    local context = T.newContext()
    local option = T.optionNamed(build(0, context, object), name)
    context:hideAndChildren()
    return option
end

--- The options of the submenu `label` in vanilla's world menu for `object`, by the keys of
--- `names` ({ key = option name }), each nil when not offered; nil without the submenu. The menu
--- is hidden again.
function T.worldOptions(object, label, names)
    local submenu, context = T.worldSubmenu(object, label)
    local options = submenu and {}
    for key, name in pairs(submenu and names or {}) do
        options[key] = submenu:getOptionFromName(name)
    end
    if context then
        context:hideAndChildren()
    end
    return options
end

-- Choosing ------------------------------------------------------------------------------------

--- Clicks `option` as ISContextMenu:onMouseUp does, with all ten parameters. A get-up option's
--- handler would run only once its ISWaitWhileGettingUp completes, behind the test's later waits;
--- the character stands, so it runs here at once.
function T.choose(option)
    if option.onSelect == ISContextMenu.onGetUpAndThen then
        option.param1(option.param2, option.param3, option.param4, option.param5, option.param6, option.param7,
            option.param8, option.param9, option.param10)
        return
    end
    option.onSelect(option.target, option.param1, option.param2, option.param3, option.param4, option.param5,
        option.param6, option.param7, option.param8, option.param9, option.param10)
end

--- Turns the character at once, body and animation, toward `target`: an object as an action's
--- faceThisObject aims at it (the nearest piece of a sprite grid, its facing position), or a
--- square's middle. An action otherwise waits for its turn (waitToStart) in real time, which
--- neither the instant cheat nor the frame rate shortens, and a square's middle isn't where the
--- game aims at an object that spans squares.
function T.face(target)
    local p = T.player()
    if instanceof(target, "IsoGridSquare") then
        local dx, dy = target:getX() + 0.5 - p:getX(), target:getY() + 0.5 - p:getY()
        if math.abs(dx) > 0.5 or math.abs(dy) > 0.5 then
            p:setTargetAndCurrentDirection(dx, dy)
        end
        return
    end
    p:faceThisObject(target)
    local forward = p:getForwardDirection()
    p:setTargetAndCurrentDirection(forward:getX(), forward:getY())
end

-- Queued menu reads ---------------------------------------------------------------------------

--- A `find` for T.useOption: the option that runs `handler` (T.optionRunning).
function T.running(handler)
    return function(context) return T.optionRunning(context, handler) end
end

--- Notes in self.menu[label] what `option` (nil when not in the menu) shows: { found, offered,
--- tooltip, submenu, name }, which T.expectOffered and T.expectOptionRefused check. Returns whether
--- it is offered.
function T.noteOption(self, label, option)
    self.menu = self.menu or {}
    self.menu[label] = { found = option ~= nil, offered = T.offered(option), tooltip = T.tooltipOf(option),
        submenu = option ~= nil and option.subOption ~= nil, name = option and option.name }
    return self.menu[label].offered
end

--- T.noteOption, then, when `option` is offered, chooses it, the character first stood next to
--- `square` (T.standNextTo) when given. Returns whether it chose it.
function T.chooseOption(self, label, option, square)
    if not T.noteOption(self, label, option) then
        return false
    end
    if square then
        T.standNextTo(square)
    end
    T.choose(option)
    return true
end

--- Queues opening the world menu of `getObject()`, looked up when the step runs, so a copy a
--- server's sync replaced is the one read, and T.noteOption of the option `find(context)` finds.
--- When `choose` and it is offered, the character faces the object (T.face) and chooses it.
function T.useOption(self, getObject, label, find, choose)
    T.step(function()
        local object = T.need(self, getObject(), "this client's copy of what " .. label .. " works on")
        local context = object and T.need(self, T.worldMenu(object), "a world menu for " .. label)
        if not context then return end
        local option = find(context)
        if T.noteOption(self, label, option) and choose then
            T.face(object)
            T.choose(option)
        end
        context:hideAndChildren()
    end)
end

--- Queues reading the names of every option, submenus' too, in the world menu of `getObject()`,
--- looked up when the step runs, into self.names[label].
function T.readMenu(self, getObject, label)
    self.names = self.names or {}
    T.step(function()
        local object = getObject()
        local context = T.need(self, object and T.worldMenu(object), "a world menu for " .. label)
        if not context then return end
        local names = {}
        T.findOption(context, function(option)
            table.insert(names, option.name)
            return false
        end)
        self.names[label] = names
        context:hideAndChildren()
    end)
end

--- Expects (`want`, or not when false) an option T.readMenu read as `label` to list `word` whole
--- among the comma-separated words of its name, where a search of the name would find "ripe" in
--- "ripening".
function T.expectWord(self, label, word, want)
    local found = false
    for _, name in ipairs(self.names and self.names[label] or {}) do
        for part in (name .. ", "):gmatch("(.-), ") do
            found = found or part == word
        end
    end
    T.expect(found == (want ~= false), label .. ": the menu " .. (found and "lists " or "doesn't list ") .. word)
end

--- Expects (`want`, or not when false) an option T.readMenu read as `label` to contain `text`.
function T.expectLine(self, label, text, want)
    local found = false
    for _, name in ipairs(self.names and self.names[label] or {}) do
        found = found or name:find(text, 1, true) ~= nil
    end
    T.expect(found == (want ~= false), label .. ": the menu " .. (found and "says " or "doesn't say ") .. text)
end

--- Expects the option T.noteOption noted as `label` offered; returns whether it was.
function T.expectOffered(self, label)
    local seen = self.menu and self.menu[label]
    return T.expect(seen and seen.offered, label .. ": not offered (" .. tostring(seen and seen.tooltip) .. ")")
end

--- Expects the option T.noteOption noted as `label` in the menu but greyed out, its tooltip saying
--- the text of `tooltipKey` when given.
function T.expectOptionRefused(self, label, tooltipKey)
    local seen = self.menu and self.menu[label]
    if T.expect(seen and seen.found, label .. ": the option isn't in the menu") then
        T.expect(not seen.offered, label .. ": offered")
        if tooltipKey then
            T.expect(seen.tooltip:find(getText(tooltipKey), 1, true) ~= nil,
                label .. ": the tooltip doesn't say " .. getText(tooltipKey) .. ": " .. seen.tooltip)
        end
    end
end
