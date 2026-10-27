require "PZHarness/ServerHandlers"
require "PZHarness/Checks"

-- Development only, not published. The server halves of the test library's reads
-- (client/PZHarness/TestReads.lua): check handlers, which answer what they found wrong, and what
-- the authority's copy of the character carries. Names of the built-in handlers start with
-- "PZHarness." so they never collide with a dev mod's.

PZHarness = PZHarness or {}

local handler = PZHarness.serverHandler

--- Registers the server check `name`, which only reads the authority's state and answers
--- { failures = { message, ... } }, which the test expects to be empty (T.expectNoFailures,
--- T.serverCheck). `fn(expect, expectNear, player, args, defer)` records what it finds wrong
--- through the PZHarness.Checks.new pair.
function PZHarness.checkHandler(name, fn)
    handler(name, function(player, args, defer)
        local expect, expectNear, failures = PZHarness.Checks.new()
        fn(expect, expectNear, player, args, defer)
        return { failures = failures }
    end)
end

-- The fluid named `name`: a FluidType's for the game's own, else the name, which the fluid
-- container looks up among the registered fluids, a mod's included.
local function fluidNamed(name)
    return FluidType[name] or name
end

-- T.readCarried: for each full type of `args.types` the character's items, bags included, { id,
-- condition, uses (the fraction left), repaired (vanilla's repair count), modData, and for a fluid
-- container the `litres` it holds and whether they are `tainted` }; in `fluids` the litres of each
-- fluid of `args.fluids` (Fluid field names, or a modded fluid's name) in the fluid containers of
-- its main inventory; and in `total` how many items its main inventory holds.
handler("PZHarness.carried", function(player, args)
    local inventory = player:getInventory()
    local items = {}
    for _, fullType in ipairs(args.types or {}) do
        items[fullType] = {}
        local all = inventory:getAllTypeRecurse(fullType)
        for i = 0, all:size() - 1 do
            local item = all:get(i)
            local fluid = item:getFluidContainer()
            table.insert(items[fullType], { id = item:getID(), condition = item:getCondition(),
                uses = item:getCurrentUsesFloat(), repaired = item:getHaveBeenRepaired(), modData = item:getModData(),
                litres = fluid and fluid:getAmount(), tainted = fluid and fluid:isTainted() })
        end
    end
    local fluids = {}
    local carried = inventory:getItems()
    for _, name in ipairs(args.fluids or {}) do
        fluids[name] = 0
        for i = 0, carried:size() - 1 do
            local container = carried:get(i):getFluidContainer()
            if container then
                fluids[name] = fluids[name] + container:getSpecificFluidAmount(Fluid[name] or Fluid.Get(name))
            end
        end
    end
    return { items = items, fluids = fluids, total = carried:size() }
end)

-- T.readCharacter: the character as the authority has it: the stats `args.stats` (CharacterStat
-- field names) in `stats`, and the XP in the perks `args.perks` (Perks field names) in `xp`, by name.
handler("PZHarness.character", function(player, args)
    local stats, xp = player:getStats(), player:getXp()
    local reply = { stats = {}, xp = {} }
    for _, name in ipairs(args.stats or {}) do
        reply.stats[name] = stats:get(PZHarness.need(CharacterStat[name], "the character stat " .. tostring(name)))
    end
    for _, name in ipairs(args.perks or {}) do
        reply.xp[name] = xp:getXP(PZHarness.need(Perks[name], "the perk " .. tostring(name)))
    end
    return reply
end)

-- T.fillCarried: empties the fluid container of every carried item of full type `args.type`, bags
-- included, fills it with `args.litres` of `args.fluid` (none when nil), and sends the item to the
-- character's client. Answers how many it `filled`.
handler("PZHarness.fill", function(player, args)
    local items, all = {}, player:getInventory():getAllTypeRecurse(args.type)
    for i = 0, all:size() - 1 do
        if all:get(i):getFluidContainer() then
            table.insert(items, all:get(i))
        end
    end
    PZHarness.need(#items > 0, "a carried " .. tostring(args.type) .. " with a fluid container on the server")
    for _, item in ipairs(items) do
        local container = item:getFluidContainer()
        container:Empty()
        if args.fluid then
            container:addFluid(fluidNamed(args.fluid), args.litres)
        end
        item:syncItemFields()
    end
    return { filled = #items }
end)
