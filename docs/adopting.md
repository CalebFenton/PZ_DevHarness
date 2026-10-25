# Adopting PZ_DevHarness

How a mod takes the harness on, what it tells the harness about itself, and the test library its tests use. The [README](../README.md) says what the harness is for; [running.md](running.md) covers the run script and [multiplayer.md](multiplayer.md) the `--mp` mode.

## Layout

| Path | What it is |
| --- | --- |
| `bin/run-client.sh` | The client runner behind a mod's `dev/run-debug-client.sh`, single player and multiplayer (`--mp`). |
| `bin/validate-server.sh` | Boots a throwaway dedicated server with the mod and fails on anything the mod logs. |
| `bin/static-check.sh` | The static check behind a mod's `dev/static-check.sh`: compiles the Lua with the game's compiler and cross-checks the mod against the installed game ([static-check.md](static-check.md)). |
| `check/` | The static check's Java probe and Python checker, and the `.pack` and `.tiles` readers it uses. |
| `lib/harness.sh` | Paths, JVM arguments, the game lock, `install_mod`, `compile_java`, and the dedicated server both scripts start (`prepare_server`, `start_server`, `stop_server`, `server_problems`). A mod's own dev scripts may source it. |
| `lib/capture.py` | Crops a [capture mode](#capture-modes)'s screenshots into the mod's captures; a mod's own extraction may import it. |
| `lib/promo.py`, `lib/fonts/` | Lays out a mod's README images, Workshop gallery, poster, preview and mod icon from those captures, imported by the mod's `art/promo/compose.py` ([workshop-page.md](workshop-page.md#laying-out-the-images)), with the NotoSans font it draws in. |
| `lib/trace.py` | Reports where a `TRACE=1` run's time went and writes it as a Perfetto timeline ([running.md](running.md#where-the-time-goes)). |
| `lib/art/`, `lib/blender.sh` | The art library a tile and item mod's `art/models` and `tools` build with: mesh and material helpers for its Blender builders, the tile, depth map and icon renderer, review sheet helpers, deterministic FBX export, the `.tiles` and texture pack writers, and the Blender invocation its `make.sh` sources ([art.md](art.md)). |
| `java/ClickToStart.java` | Starts the client, presses "Click to start" on the loading screen, gives the asset loader more threads (`java/AssetLoading.java`), loads the tile depth maps early (`java/DepthMaps.java`) and in multiplayer sends every packet at once (`java/NetLatency.java`). |
| `java/FastServer.java` | Starts the dedicated server of `--mp` and `validate-server.sh` with the same wider asset loader, sending every packet at once. |
| `mod/42/` | The harness mod (`cf_test_harness`): `client/PZHarness/Runner.lua`, `TestLib.lua`, `ServerCalls.lua` and `Leaks.lua`, the leak check between tests, `Trace.lua`, what a `TRACE=1` run records, `Capture.lua`, the steps and shots of [capture modes](#capture-modes), `Stage.lua` and `StageLots.lua`, their [staging](#staging), and `QA.lua`, the setup of [QA scenarios](#qa-scenarios); `server/PZHarness/ServerHandlers.lua`, the server's half of the tests' server channel, `ServerFixtures.lua`, the server's half of the two-sided fixtures, `ServerChecks.lua`, of server checks and [reads](#the-test-library) of what the character carries, and `ServerLearning.lua`, of [recipe learning](#the-test-library); `shared/PZHarness/Fixtures.lua`, what both halves do, `Checks.lua`, expectations for server handlers, `Loot.lua`, the loot tables and rolls of [loot checks and reports](#loot), and `Snapshot.lua`, what the leak check reads on each side. |

## Adopting it

The harness sits in the mod's repository at `dev/harness`:

```sh
git submodule add https://github.com/CalebFenton/PZ_DevHarness.git dev/harness
```

The mod then needs three things.

### `dev/harness.conf`

Sourced bash. Paths are relative to the repository. The mod's id and name come from its
`mod.info`, so they aren't repeated here.

| Key | Meaning |
| --- | --- |
| `MOD_DIR` | The published mod's folder, such as `Contents/mods/MyMod`. It is copied into the cache. |
| `DEV_MOD_DIR` | The dev mod's folder, such as `dev/MyModDevHarness`. It is linked into the cache. |
| `LIBRARY_MODS` | Optional: a bash array of the library mods the published mod requires, in load order, such as `(../MyLib/Contents/mods/MyLib)`: each a mod folder with a `42/mod.info`, in a repository of its own checked out beside the mod's, so the path leaves this one. Every client and server run copies each one into the cache as it does the published mod and enables them first, a Lua stack trace through one fails the run as one through the mod does, and the static check reads and checks them as published code, failing unless the published `mod.info`'s `require=` names exactly their ids ([static-check.md](static-check.md#the-checks)). A script fails at once if one is missing. Their changes are not in `--changed`'s batch ([running.md](running.md#choosing-tests)). The Workshop page lists each as a Required Item ([workshop-page.md](workshop-page.md#the-process)). |
| `CACHE_NAME` | Cache dirs go to `$TMPDIR/<name>-client`, `-server`, `-mpclient`, `-mpserver` and `-check` (the static check). |
| `TAG` | The console tag of the tests' lines, such as `MyModTest`. |
| `RELOAD_FILES` | A bash array of globs, relative to the dev mod, of the files a kept game loads again for a rerun, in load order (the mod's test library first). With `--mp` the server loads those under `media/lua/server` and `media/lua/shared` again too, so list the dev mod's server handler files here. |
| `MODES` | The mod's other modes, space-separated; each becomes a `--<mode>` flag. |
| `MODE_MARK_<mode>` | The console mark of the mode's lines; the run waits for `<mark> DONE`. |
| `MODE_SELECTION_<mode>` | Optional: the environment variable whose value the mode's handler gets as its selection, as `TESTS` is for `--test`. |
| `MODE_GROUPS_<mode>` | Optional: the groups a [capture mode](#capture-modes) shoots, space-separated, in the order a run takes them. The selection may name only these, or the run fails before the game starts and lists them; the handler gets the named ones, or every group if the selection names none, comma-separated in this order. |
| `MODE_CAPTURES_<mode>` | Optional: the folder, such as `art/promo/captures`, that a [capture mode](#capture-modes)'s shots are cropped into after a run that finished cleanly. |
| `TEST_MAP` | Optional: a bash array of `'<glob>=<prefix>,<prefix>'` entries for `--test --changed` and for the `suspects` lines after a failure ([running.md](running.md#choosing-tests)). Each glob is matched against paths relative to the repository with bash's `[[ == ]]`, where `*` crosses `/`; every entry a file matches adds its test name prefixes (`=<name>` for one test exactly), and an empty list (`'<glob>='`) adds none. Every file under the mod, the dev mod and the harness mod needs an entry, and every glob must match one of those files: `dev/static-check.sh` and `--changed` fail otherwise, naming each file without a line and each glob that matches none, so a new or renamed file shows up in the map at once. A file every test depends on names the mod's test prefix, the `prefix` it registers, which selects every test; files elsewhere, such as docs and art, reach no test and take no entry. The runner fails a prefix that names no test. |
| `PRECHECK` | Optional: a bash array, the command every game run of the harness runs first from the repository, normally `(dev/static-check.sh)` ([static-check.md](static-check.md)). If it fails, no game starts. |
| `CHECK_PLUGINS` | Optional: a bash array of Python files with the mod's own static check rules ([static-check.md](static-check.md#plugins)). |
| `CHECK_ALL_LANGUAGES` | Optional: set to make the static check fail on any language the game offers that lacks a translation file or key English has. |
| `QUIET_WORLD` | Optional: a bash array of `Key=value` sandbox options that make a `--test` world quiet, replacing the harness's list ([running.md](running.md#a-quiet-world)); `QUIET_WORLD=()` keeps the world's own population. |
| `SERVER_PROBLEMS` | Optional: an extended regex of server log lines that count as the mod's problems, besides stack traces through it. |
| `SERVER_IGNORE` | Optional: an extended regex of matching lines that don't count. |
| `WORKSHOP_REPO` | Optional: the GitHub repository, as `owner/name`, whose `README.md` [`dev/workshop-txt.sh`](workshop-page.md) turns into `workshop.txt`'s description; its relative images and links point there. With it set, the static check fails while `workshop.txt` is out of date or over Steam's limit. |
| `WORKSHOP_BRANCH` | Optional: the branch those images and links point to; `master` by default. |
| `WORKSHOP_SKIP` | Optional: a bash array of the README's `##` headings to leave off the Workshop page, such as `(Install Development)`. |
| `WORKSHOP_GALLERY` | Optional: the folder of gallery images [`dev/workshop-gallery.sh --upload`](workshop-page.md#the-gallery) puts on the Workshop item; `art/promo/gallery` by default. |

Hooks, bash functions the conf may define:

| Hook | When it runs |
| --- | --- |
| `harness_check_<mode>` | Before the lock and the launch. `$SELECTION` holds the selection; exit nonzero to refuse it, so a typo fails at once. |
| `harness_after_<mode>` | After a run of the mode that finished cleanly, instead of the harness's own ending: with `MODE_CAPTURES_<mode>`, `lib/capture.py` crops the shots into that folder and the run prints `PASS: captures are in <folder>`; for a mode that saved `<mode>_*.png` screenshots, `PASS: screenshots are in <folder>`; else `PASS`. Define it for more, such as captures of the mod's own. |
| `harness_server_setup` | After a server's `$CACHE/Server/$SERVER_NAME.ini` is written: in `validate-server.sh`, and for the server of `--mp`, whose sandbox then gets `Zombies = 6` and the `QUIET_WORLD` options it doesn't set appended; add files such as `${SERVER_NAME}_SandboxVars.lua`. `$MP` is `1` for the `--mp` server. |

Hooks can read `$REPO`, `$CACHE`, `$MOD_DIR`, `$DEV_MOD_DIR` (absolute by then), `$MODE` and `$MP`;
in `validate-server.sh` both are empty.

### Entry points

Thin scripts that source the harness, so `$0` and the usage line name the mod's script:

```sh
#!/usr/bin/env bash
# dev/run-debug-client.sh
. "$(dirname "$0")/harness/bin/run-client.sh"
```

```sh
#!/usr/bin/env bash
# dev/validate-server.sh
. "$(dirname "$0")/harness/bin/validate-server.sh"
```

```sh
#!/usr/bin/env bash
# dev/static-check.sh
. "$(dirname "$0")/harness/bin/static-check.sh"
```

```sh
#!/usr/bin/env bash
# dev/workshop-txt.sh, with WORKSHOP_REPO set
. "$(dirname "$0")/harness/bin/workshop-txt.sh"
```

```sh
#!/usr/bin/env bash
# dev/workshop-gallery.sh
. "$(dirname "$0")/harness/bin/workshop-gallery.sh"
```

### The dev mod

`<DEV_MOD_DIR>/42/mod.info` with `require=<the mod's id>,cf_test_harness`, holding the debug
scenario (a `debugScenarios` entry), the tests, the fixtures that know the mod's objects and the
handlers of the mod's modes. Nothing of it is published, so the published mod carries game code
only. One file registers the mod with the runner at load:

```lua
require "PZHarness/Runner"
require "MyMod/Debug/MyModDebugScenario"

PZHarness.register({
    scenario = "MyModScenario",   -- its key in debugScenarios; every mode starts it
    prefix = "mymod_",            -- --test runs the TimedActionTests whose names start with it
    modes = {
        -- run(selection, done) starts once the world around the character has loaded and
        -- calls done() when finished; done prints "<mark> DONE" and quits. The flags are optional;
        -- see [capture settings](#capture-settings).
        shots = { uncapped = true, clearWeather = true, fastUI = true,
            run = function(selection, done) Shots.capture(selection, done) end },
    },
    onStart = function(mode) end, -- optional, after the scenario's own onStart in every mode
})
```

The test library's settings and hooks go in a file of the dev mod's shared Lua, since a
multiplayer server loads no client Lua and both sides read the same registration: in single player
a fixture placed through the server channel (`placeTile`, `placeBench`, `placeVehicle`) and one
placed directly (`tile`, `bench`, `track`) are removed by the same `remove`.

```lua
-- <DEV_MOD_DIR>/42/media/lua/shared/MyMod/Debug/MyModTestSettings.lua
require "PZHarness/Fixtures"

PZHarness.registerTests({
    hour = 10,
    sandbox = "MyMod",
    -- MyMod.Debug is client Lua, which loads after this file: look it up when called.
    isFreeSquare = function(square, indoors) return MyMod.Debug.isFreeSquare(square, indoors) end,
    remove = function(object) return MyMod.removeIfMine(object) end,
})
```

Every setting is optional:

| Setting | Side | What it does |
| --- | --- | --- |
| `hour` | client | The hour every test runs at unless its spec gives one; a test first waits for the light to follow the clock. |
| `perks` | client | Perks (`Perks.Electricity`) restored after every test, however it changed them, at the XP that starts their level; the server's copy too. |
| `sandbox` | both | The mod's table in `SandboxVars`, which `setSandbox` tries before the game's options and `saveOptions` saves from. |
| `sandboxChanged()` | both | Called on each side after its copy of a sandbox option is set or restored, for state the mod derives from its options. |
| `setup(self, spec)` | client | Called before every `spec.run`, after its hour and sandbox options; may push undos with `defer`. |
| `recipePrefix` | client | The name prefix of the mod's craftRecipes, for `recipeNames`, `learnRecipes`, `learnableRecipeNames`, `craftTest`. |
| `isFreeSquare(square, indoors)` | client | Where `squares` may put a fixture; by default a walkable square without a vehicle, indoors or outdoors as asked. |
| `remove(object)` | both | Removes a placed object of the mod the way the mod does and returns true; anything it returns false for goes the vanilla way, a running generator switched off first. Every fixture removed when a test ends goes through it, whichever side placed it. |
| `spawnVehicle(script, square, facing, args)` | server | Makes the vehicles `placeVehicle` asks for, with the test's `opts.args`, returning one, or nil to leave it to `addVehicleDebug`. |
| `leakRadius` | client | Squares each way the [leak check](running.md#leaks-and-desyncs) reads; by default a little past where `squares` looks. |
| `leakLevels` | client | The z levels the leak check reads; the character's own by default. |
| `leakIgnore` | client | Lua patterns over `"<sprite>@<class>"` the leak check leaves out, past the built-in ones. |

"Server" is the authority: the dedicated server in multiplayer, the one game in single player. A
hook that calls the dev mod's client or server modules looks them up when it runs, since those load
after shared Lua and each side loads only its own.

The scenario's setup goes in a module of the dev mod that the scenario and the tests both require.
It lives under the mod's own global table, so it can't collide with another mod's, and returns
itself, so a file that needs it names it in its `require`:

```lua
-- <DEV_MOD_DIR>/42/media/lua/client/MyMod/Debug/MyModDebug.lua
require "PZHarness/TestLib"

MyMod = MyMod or {}
local Debug = {}
MyMod.Debug = Debug

function Debug.setupPlayer(player)
    PZHarness.Test.learnRecipes(player)
    PZHarness.Test.placeWorkTable(player)
end

return Debug
```

```lua
-- <DEV_MOD_DIR>/42/media/lua/client/MyMod/Debug/MyModDebugScenario.lua
local Debug = require "MyMod/Debug/MyModDebug"

debugScenarios = debugScenarios or {}
debugScenarios.MyModScenario = {
    name = "My Mod",
    startLoc = { x = 10835, y = 10144, z = 0 }, -- DebugScenarios needs one
    onStart = function()
        Debug.setupPlayer(getPlayer())
    end,
}
```

The runner records the run's mods (the libraries, the mod, the harness mod and the dev mod) for
the scenario's new save and turns zombies off (`PZHarness.wrapSetSandbox(scenario)`), so a
scenario's own `setSandbox`, which runs after, only sets what the mod needs.

The mod's test library inherits the shared one and adds its fixtures:

```lua
require "PZHarness/TestLib"
require "PZHarness/TestMenus" -- each library module its tests use ("The test library" below)
MyModTest = setmetatable({}, { __index = PZHarness.Test })
local T = MyModTest

function T.gadget(self, square) return T.tile(self, square, "mymod_01_0") end
```

Test files register tests with `T.test(name, spec)`; `PZHarness/TestLib.lua` explains the spec,
the restore stack and the rules that keep each test independent of the ones before it.

What only the authority can do goes in the dev mod's server Lua, as named handlers that tests call
with `T.server` (see [multiplayer.md](multiplayer.md)):

```lua
-- <DEV_MOD_DIR>/42/media/lua/server/MyMod/Debug/MyModTestServer.lua
require "PZHarness/ServerHandlers"

PZHarness.serverHandler("placeThing", function(player, args, defer)
    local square = getSquare(args.x, args.y, args.z)
    if not square then return nil, "a loaded square for the thing" end -- fails the test as T.need does
    local thing = MyMod.place(square)
    defer(function() MyMod.remove(thing) end) -- undone on the server when the calling test ends
    return { x = args.x, y = args.y, z = args.z } -- plain values: strings, numbers, booleans, tables
end)
```

A handler that checks many things on the server registers with `PZHarness.checkHandler(name, fn)`,
from `PZHarness/ServerChecks.lua`, and answers with what it found wrong for the test to report.
`fn(expect, expectNear, player, args, defer)` gets the pair `PZHarness.Checks.new()` makes
(`PZHarness/Checks.lua`), which work as the test library's do and fill the answer's `failures`;
what it can't find it takes through `PZHarness.need`, as any handler does. A
test expects the answer empty with `expectNoFailures`, or `serverCheck` registers a whole test of
one check:

```lua
require "PZHarness/ServerChecks"

PZHarness.checkHandler("thingsStocked", function(expect, expectNear)
    expect(MyMod.stock ~= nil, "no stock table")
    expectNear("the stock's weight", MyMod.stockWeight(), 2.5)
end)
```

```lua
-- a test file
T.serverCheck("my_mod_things_are_stocked", "thingsStocked")
```

#### QA scenarios

A second scenario beside the mod's, for playing through the mod by hand, comes from `PZHarness.QA`, in
`PZHarness/QA.lua`: `QA.scenario(name, startLoc, setup)` is a `debugScenarios` entry whose new save
gets the active mods and no zombies as the runner's does (the scenario panel records no mods, and
a save without them loads without them), and that calls `setup(player)` on the world's first tick,
once the global object systems exist. For `setup`:

- `setUpCharacter(player)`: god mode, invisible, carrying anything without tiring, every perk of
  the `perks` setting at `QA.SKILL` (the top) and every recipe of the mod; `learnAllRecipes(player)`
  is the last alone, `learnRecipes` plus the build menu's (`buildRecipeNames`), which a main
  scenario's setup may call too.
- `materials(names, prefer)`: what making each of the recipes `names` (craftRecipes or build menu
  recipes; `modRecipeNames()` is all of the mod's) once takes, as `{ type, fluid, used, kept }` by
  item type and the fluid it holds, sorted by display category and type, plus the inputs no item
  meets. Each input is `inputItem`'s pick, `inputCount` of it, so drainables count by their uses;
  `kept` is the most of a kept tool one recipe needs, `used` the sum of what all use up.
- `isKnown(fullType)`, `newItem(fullType, fluid)` (its fluid container full of `fluid`; nil for a
  type the game lacks), and `buildAsPlayer(player, sprite, nSprite, x, y, z)`, which builds the
  build menu entity of the tile `sprite` there as the build menu does (`ISBuildIsoEntity:create`),
  turned by the cursor's rotation `nSprite`, the build cheat standing in for materials and the job;
  it returns what is missing, or nil.
- `printSummary(mark, line, summary, lists)` prints `line` under `mark`, then one line for each
  field of `summary` named in `lists` that is a non-empty list or a string: what the setup laid
  out, then what it couldn't.

```lua
-- <DEV_MOD_DIR>/42/media/lua/client/MyMod/Debug/MyModDebugScenario.lua, continued
local QA = require "PZHarness/QA"

debugScenarios.MyModQAScenario = QA.scenario("My Mod QA", { x = 10835, y = 10144, z = 0 }, function(player)
    QA.setUpCharacter(player)
    local needs, unmatched = QA.materials(QA.modRecipeNames())
    for _, need in ipairs(needs) do
        for _ = 1, need.used + need.kept do
            player:getCurrentSquare():AddWorldInventoryItem(QA.newItem(need.type, need.fluid), 0.5, 0.5, 0)
        end
    end
    QA.printSummary("MYQA", "laid out " .. #needs .. " types", { unmatched = unmatched }, { "unmatched" })
end)
```

## The test library

`PZHarness.Test`, from `PZHarness/TestLib.lua`:

- Registering: `test(name, spec)`, `craftTest(name, spec)`. `spec.spOnly` or `spec.mpOnly`, a reason string, keeps a test out of the other mode. A test still busy after 30 seconds of real time fails with what it was waiting on (the queued action's type, or which server answer or wait; `waitUntil(condition, maxMs, what)` names a wait), its queue is cleared, its undos run and the next test starts; `spec.timeoutSeconds` raises the limit for a test that is slow on purpose. A test whose starting square still hasn't loaded, some seconds after the test before it took the character far away, fails without running, and the next one waits for the square again.
- Expectations: `expect`, `expectNear`, `expectEqual(label, actual, expected)` (worded as `expectNear`: "label is X, expected Y"), `need`. Once a test misses something, its later queued steps and waits don't run.
- Restore stack, two-sided (see [two-sided fixtures](multiplayer.md#two-sided-fixtures)): `defer`, `onTick`, `setTime`, `setPerk`, `setSandbox`, `setMultiplier`, `setGrid`, `setMechanicsCheat`, `makeDark`, `changeItem`; `spec.instant` and the `perks` setting too. `setTime`'s undo puts back the date with the hour, since a clock run past midnight moves the world to the next day. A multiplayer server times every action in real time, and an instant vehicle part install or uninstall on a client stops as invalid once the server has moved the part, so a test turns `setMechanicsCheat` on around those instead. Vanilla's `ISInstallVehiclePart:new` takes its time from its caller and never asks its `getDuration`, so neither cheat shortens an install: `shortenQueuedInstalls()`, in the step that queued one (`ISVehiclePartMenu.onInstallPart`), gives it the time `getDuration` gives.
- Queue: `wait`, `waitUntil`, `waitFor`, `waitForLight`, `step`. `wait(ticks)` counts ticks; the others count real milliseconds, since the uncapped frame rate makes ticks come faster or slower. `waitUntil(condition, maxMs, what)` ends as soon as `condition()` holds or `maxMs` pass, and validate checks what it waited for; `waitFor(self, condition, what, ms)` waits the same (ten seconds unless `ms` says otherwise), then fails the test as missing `what` if the condition never held, so a copy that never reached this client can't pass, and keeps the condition's last answer without calling it again; `waitForLight(self)` is `waitFor` for light where the character stands, which the game wants for a craft or a build and which lags the clock. The light must hold for two of the lighting thread's updates: one reading can be a square's light from before a clock change, which the next update replaces. What a step queues runs right after it, in order (vanilla's adding-actions mode), and a clear of the queue inside it (`luautils.walkAdj`) drops only that. Any other clear of the queue while the test's own waits and steps are still in it, such as a timed action that turns invalid or is refused, fails the test at once with the action that was running (a walk with where it went from and to), and validate doesn't run.
- The server: `server(self, name, args)` calls the dev mod's handler `name` and leaves its answer in `self.server[name]` exactly as the handler returned it, so `false`, `0` and `nil` arrive as themselves; `serverUntil(self, name, args, done, maxMs)` calls it until `done(reply)`; `give(self, name, items)`; `count(self, name, types, opts)`; `batch(fn)` sends the calls `fn` queues back to back in one round trip ([multiplayer.md](multiplayer.md#the-server-channel)).
- Reads, from `PZHarness/TestReads.lua`, which a mod's test library requires to have them: `read(self, name, args, label)` is `server` that also keeps the answer in `self.reads[label]`, when a label is given, for a test that reads one handler at several points; `readUntil(self, name, args, label, done, maxMs)` is `serverUntil` into `self.reads[label]`. Server checks (`PZHarness.checkHandler`, above): `expectNoFailures(answer)` expects a check's `failures` empty, and no answer fails too; `serverCheck(testName, name, args)` registers a test that runs one check. What the character carries: `carried(fullType)` is this client's first, in any bag, or nil; `waitForCarried(self, fullType, what)` waits for one as `waitFor`; `readCarried(self, types, fluids, label)` reads the server's copy (handler `PZHarness.carried`) into `self.reads[label]`, `"carried"` unless given, and `carriedItems(self, fullType, label)` (a list, empty without any) and `carriedFirst(self, fullType, label)` read it back, each item `{ id, condition, uses, repaired, modData, litres, tainted }`: `uses` the fraction left, `repaired` vanilla's repair count, `litres` and `tainted` a fluid container's; the answer also has `fluids`, the litres of each of `fluids` in the main inventory's containers, and `total`, how many items the main inventory holds. `fillCarried(self, fullType, fluid, litres)` empties every carried fluid container of `fullType` on the server (handler `PZHarness.fill`), fills each with `litres` of `fluid` (a FluidType name, or a mod's fluid; nil leaves them empty), and waits with `waitForFluid(self, fullType, litres)` until this client's first holds that much, or all it can, as a craft or a menu reads this client's copy. `overlaysOf(object)` is `PZHarness.Fixtures.overlaysOf` on this client.
- Verdicts: `printVerdict(name, failures, seconds)` prints a test's PASS or FAIL line. The harness runner prints it once its leak check after the test is done ([running.md](running.md#leaks-and-desyncs)); the debug menu's runner gets it from validate.
- Squares and fixtures: `squares`, `track`; placed by the server: `placeTile`, `placeBench`, `placeVehicle`; placed and picked up by the character, as a player does with the moveables cursor: `placeAsPlayer(self, square, itemType, sprite, modData)` (a handle `{ x, y, z, square }`, `object` once this client has it, removed when the test ends) and `pickUpAsPlayer(self, handleOrSquare, sprite)`; this game only: `tile`, `placeMoveable`, `bench`, `vehicle`; `lineUpTrailer`.
- Crafting: `recipeNames`, `buildRecipeNames` (the build menu's recipes, which `getAllCraftRecipes`, and so `recipeNames`, leaves out), `learnRecipes`, `forgetRecipes`, `recipeInputs`, `addRecipeInputs` (this game only), `inputItem(input, prefer)`, `inputCount(input, item)`, `placeWorkTable`, `craftRefusal`, `startCraft`. `inputItem` is the script item `recipeInputs` picks for one of a recipe's inputs: the first of its possible items named in `prefer`, else the first that isn't a generic `Base.Moveable`; `inputCount` is how many of it `recipeInputs` gives: an input's amount, or for a drainable input that counts uses as many full items as the uses need (two sand bags for eight uses). Any test that starts a craft with `startCraft` and fails also reports why the game refused it, at the start or, for a craft it queued and then dropped, at perform, so a mod's own craft tests get that without `craftTest`. A `craftTest` with `spec.refused` expects the game to refuse the craft.
- Learning recipes, from `PZHarness/TestLearning.lua`, which a mod's test library requires (`TestBuild.lua` requires it too), its server half `ServerLearning.lua`: each puts back on both sides, when the test ends, what it changed. `knowRecipes(self, names, known)` queues the character knowing the recipes `names` on both sides (`known = false`: forgetting them); at the end each side knows exactly what it knew before, and no longer any recipe a level up taught meanwhile, which the leak check would count. `levelUp(self, perk, levels)` queues setting the authority's `levels` (perk id -> level, at the XP that starts each) and then awarding the XP that takes `perk` (an id) one level up, as the authority awards a timed action's: the game fires `LevelPerk`, so vanilla's AutoLearn and a mod's learning on a level up run as in play; `{ before, after }`, the perk's level, lands in `self.server["PZHarness.levelUp"]`. `setLevelsQuietly(self, levels, names)` sets them with no level up, for a character who earned them before a mod was added, and answers what the authority knows of `names` right after as `known` in `self.server["PZHarness.setLevelsQuietly"]`; the server sends a client its levels at its next perk sync. Reading: `recipesKnown(names)` is which of `names` this client's copy knows, by name, judged by the recipe as the crafting menus judge it, counting its MetaRecipe (`PZHarness.Fixtures.knows(player, names)` on either side; the handler `PZHarness.recipesKnown` answers the authority's as `known`); `waitForKnown(self, names, expected)` queues waits until the authority and then this client know each of `names` that `expected` marks true, leaving each side's `recipesKnown` in `self.known` (`{ server, client }`), and `expectKnown(self, names, what, expected)` expects both to know exactly those. From the scripts: `learnableRecipeNames(prefix)`, every craftRecipe and build menu recipe starting with `prefix` (the `recipePrefix` setting by default; a test file that reads them at load names it, as the setting may register later) that has to be learned; `autoLearnLevels(names)`, each perk and level their AutoLearn skills name, `{ perk, level }` once each, and the highest; `autoLearnedAt(names, perk, level)`, which of them a character with `perk` at `level` and every other perk at 0 meets the AutoLearn skills of; `autoLearnLevelsWith(rows, perk, level)`, levels for `levelUp` or `setLevelsQuietly` with each perk of `rows` at 0 but `perk` at `level`. `autoLearnTests(prefix, names, opts)` registers a mod's tests of learning `names` by level: `prefix .. "_learning_level_up_teaches_at_the_auto_learn_level"` (each perk and level up, both sides know exactly what it earns; `opts.timeoutSeconds`) and, given `opts.catchUp` (a function sending the client's catch-up request), the multiplayer-only `prefix .. "_learning_joining_server_catches_up_earned_recipes"`.
- Building from the build menu, from `PZHarness/TestBuild.lua`, which a mod's test library requires: `buildEntry(entity)` is the build menu entry of a game entity (its full name), or nil; `setRecipeSkills(self, recipe)` sets the levels a recipe requires until the test ends; `placeable(entity, square)` is whether the entity's build cursor takes the square (`ISBuildIsoEntity:isValid`, the entity's `OnIsValid` among it; inputs aside, though a hammer among the recipe's tools must be carried), nil without the entry. `buildSite(self)` is the square to build on nearest the character, or nil and missing: bare outdoor ground with open ground (`Stage.isOpenGround`) two squares all round it, as far as the build menu reaches for containers from beside it. So the build takes only what the character carries, and no wall shades the site or turns the walk beside it; a container left in reach can be out of reach once the build has walked the character, which refuses the whole build without a word (`BaseCraftingLogic.isContainersAccessible`). `build(self, entity, square, prefer, arrived, what)` builds on a `buildSite` square through the menu's own path (`ISBuildIsoEntity`, `ISBuildAction`): the character knows the recipe (`knowRecipes`) and has its levels, carries exactly its inputs (`recipeInputs` with `prefer`), goes next to the square (`goNextTo`) and waits for light, as the game refuses a build in the dark; a build the menu refuses, for its inputs or its square, is missing at once with the reason (the recipe unknown, a skill short, the dark, or its inputs), and otherwise the test waits until `arrived()` holds on this client, else misses `what`. A mod that removes what a build leaves through its own handler queues that handler before `build`. It returns the build, or nil: `types` its inputs' full types, `expected` what it should leave carried of them, and once built `face`, the upper-case name of the face it built. `expectBuildUsed(build, left)` expects `left`, `count`'s counts of `types` afterwards, to be `expected`: the kept tools still there, none of what it takes whole, and a drainable it takes uses of not counted.
- Lookups: `player`, `objectWithSprite`, `countPairs`; `PZHarness.Fixtures` has these and `vehicleById` for server handlers too, `squareAt(at)` (the loaded square at `at`'s x, y, z, or nil), `overlaysOf(object)` (the sprite names of the overlays its tile shows, in drawing order), `fieldsOf(source, keys)` (the fields `keys` of `source`, a record's saved fields, as an answer; tables are copied, so a single-player answer keeps what they held at the read, as one that crossed the network does), `ring(x, y, r)`, which iterates (`for sx, sy in ...`) over the squares at exactly `r` squares from x, y, each once, for a search that widens ring by ring from the nearest, and `teleportToMiddle(player, x, y, z)`: `teleportTo` alone leaves the character on the square's north-west corner, from where vanilla's `walkAdj` takes a square two to the north or west as in reach, walks nowhere, and an action that needs the square adjacent stops.
- Building and removing in a server handler, as the library's own fixtures do on either side (`PZHarness.Fixtures`): `newTile(square, sprite, modData)`, `newBench(square, entity, sprite, player)` (the bench, or nil and what is missing), `freeAdjacentSquare(here, used)`, and `removePlaced(thing)`, which removes an object through the `remove` setting, else the vanilla way, or a vehicle permanently; a server sends each to its clients.
- Undoing in a server handler (`PZHarness.Fixtures`): `deferOnce(defer, undo)` defers `undo` and returns the function that runs it now, for a handler that puts shared state back before it answers; `undo` runs once, then or when the test ends, whichever comes first, so a handler that throws first still undoes. `saveOptions(defer, names, reapply)` saves the mod's options `names` (its table in `SandboxVars`, the `sandbox` setting) for a handler that changes them itself, and returns that function for putting them back and then calling `reapply()`, if given, to rebuild what the mod made from them. Unlike `setSandbox`, it leaves the game's `SandboxOptions` copy alone.
- Walking: `standNextTo(square)` puts the character where vanilla's `walkAdj` would walk it, facing `square`, so the walk a menu option or an action queues first has no way to go and the turn an action's `waitToStart` waits for (`faceThisObject`, `shouldBeTurning`) is already done; walking and turning take real time, which neither the instant cheat nor the frame rate shortens. `goNextTo(self, square)` queues the same, then on a multiplayer client puts the server's copy of the character there too, so an instant action's `complete()` finds it in reach: left alone, the server hears of the move only on the client's next timed position update, up to a second later, and then walks its copy over from wherever the updates before put it (the runner's move to the test's start among them). The client sends its new position at once, and the server's copy is moved after that update has reached it, so nothing older can move it back. A test that queues an action whose `complete()` checks the character's reach goes there this way, and queues the menu's own job a step later: the character's square catches up with a teleport only on its next update, and `walkAdj` judged from the old square queues a walk to where the character already stands, whose path can fail and clear the queue. `placeAsPlayer` and `pickUpAsPlayer` do all this themselves.
- Context menus, from `PZHarness/TestMenus.lua`, which a mod's test library requires to have them: read a menu inside one step and hide it (`hideAndChildren`) before the step ends. Building: `worldMenu(object)` and `inventoryMenu(item)` (the menu vanilla's right-click builds, or nil), `newContext()` (an empty one for a mod's own option builder), `subMenu(menu, option)`, `worldSubmenu(object, label)` (the submenu and the menu to hide), `partMenu(vehicle, part)` (the mechanics window's menu for a vehicle part). Finding: `optionNamed(menu, name)` and `optionNames(menu)` look at the top level only; `findOption(menu, matches)`, `findNamed(menu, name)`, `optionRunning(menu, handler)`, `inSubmenu(menu, nameKey, matches)` and `optionFor(menu, item)` (the option passing `item` as its third parameter, matched by id) search every submenu too: each submenu belongs to the player's root menu, so any menu of the tree finds them. `optionRunning` also finds a get-up option (`ISContextMenu.onGetUpAndThen`), which carries its handler as its first parameter. Reading: `offered(option)` (there and not greyed out), `tooltipOf(option)` (its tooltip text, `""` without one), `optionState(option)` (`{ shown, greyed, reason }`), `menuOption(build, object, name)` (the option a mod's `build(0, context, object)` adds to a fresh menu), `worldOptions(object, label, names)` (a world submenu's options by key). Noting: `noteOption(self, label, option)` notes in `self.menu[label]` what an option shows (`{ found, offered, tooltip, submenu, name }`) and returns whether it is offered; `chooseOption(self, label, option, square)` notes it and chooses it when offered, the character first stood next to `square` when given. Clicking: `choose(option)` passes all ten parameters as a click does, and runs a get-up option's handler at once, as the character already stands, where vanilla would queue it behind the test's later waits; `face(target)` turns the character to an object or square's middle at once, as an action's `waitToStart` would in real time. Queued: `useOption(self, getObject, label, find, choose)` opens the world menu of `getObject()` when its step runs, notes what `find(context)` found (`noteOption`) and, with `choose`, faces the object and chooses an offered option; `running(handler)` is a `find` for `optionRunning`; `readMenu(self, getObject, label)` puts the names of every option in `self.names[label]`. Checks on those: `expectOffered(self, label)`, `expectOptionRefused(self, label, tooltipKey)` (in the menu, greyed out, its tooltip saying `tooltipKey`'s text when given), `expectWord(self, label, word, want)` (an option's name lists `word` whole among its comma-separated words) and `expectLine(self, label, text, want)`; `want = false` expects the opposite.
- Chunk reload trips, from `PZHarness/TestChunks.lua`, which a mod's test library requires to have them: `reloadChunk(self, at, whileAway)` queues a trip that unloads the chunk of `at` (`{ x, y, z }`) and loads it again, for what a mod's objects do while their chunk is away and what they come back as from the save. The character goes far east of `at`, stays away two seconds once this client has let the chunk go (back at once, a chunk has been seen to load with a vehicle a test had removed before the trip), and comes back to the square they stood on when the trip set off; `whileAway()`, if given, queues what happens meanwhile. A chunk that doesn't unload or load again within `CHUNK_MS` real milliseconds, or comes back without a `LoadChunk` event (from a cache, with its state), fails the test as missing it, and a test that ends with the character still away puts them back. A multiplayer server keeps chunks loaded long after the character leaves, so there the trip reloads only this client's copy, which the server sends again; a test that needs the authority's chunk gone too is `spOnly = CHUNK_RELOAD_SP_ONLY`. `CHUNK_RELOAD_SECONDS` is a `spec.timeoutSeconds` for a test with a trip, and `CHUNK_MS` serves a test's own waits for far squares to load. `teleporter(self)` returns `teleport(x, y, z)`, which moves the character on the next tick until the test ends: a teleport from inside a timed action doesn't stick.

## Loot

`PZHarness.Loot`, from `PZHarness/Loot.lua`, for a dev mod's loot checks (server handlers, since
only the authority's loot tables are filled) and its loot report mode, which rolls on the client.
It is shared Lua, so both roll the same way. What the mod puts in which lists, and the labels a
report prints, stay in the dev mod.

- The tables: `forEachItemsList(fn)` calls `fn(items, path)` for every `items` list of every room, container, bag, procedural and vehicle table. `procListUsers()` is, for each `ProceduralDistributions` list, the first procedural room container that picks it (`{ room, container }`): `ItemPickerJava.getItemContainer` finds a list only through one. `proceduralList(name, users)` is the game's parsed copy of a list, and that user, or nil. `rarityOf(fullType)` is the loot rarity option that scales an item (its name and the option), or nil and the item's loot type.
- Options: `withMeasureOptions(options, fn)` runs `fn` with the game's sandbox options `options` (name -> value, or `DEFAULT` for the option's default) and the General debug log off, which in debug mode logs every roll into a container off the map. It reloads the loot multipliers, which the game caches, on both sides of `fn` (`ItemPickerJava.InitSandboxLootSettings`), and puts everything back even when `fn` throws, as `restoring(fn, restore)` does for a mod's own changes. A mod's own loot options in a server check go through `PZHarness.Fixtures.saveOptions`.
- Rolling: `withParsed(containers, lists, fn)` has the game parse container tables of the dev mod's making (under a made-up room, with `lists` for the procedural ones to pick), passes `fn` the parsed copies by key, then takes them out and parses again. `rollFill(list)` is a fill that rolls a parsed table as a container fill does. `fillOnce(fill, container, read)` empties a scratch container, fills it and returns `read(container)`: by default `countItems(container)`, fullType -> count with bags' contents, and `countItems(container, matches)` counts only the types `matches(fullType)` takes. `sample(fill, samples, container, read)` fills `samples` times and gives, for each key `read` counts, the `share` of samples with one and the mean count in those, `perContainer`. Each fill's items come off the cell's processed items (`forgetItems(container)`), where `ItemContainer.AddItem` puts every new item and thousands of fills in one frame would pile up until the game runs out of memory.
- `squareOutsideRooms(character)` is the nearest ground-floor square in no room, for a container that rolls procedural tables: only one on a square does, and one in a room counts toward the room's list limits.

## Capture settings

Flags of a registered mode, for modes that take screenshots. They take effect just before `run`;
`done()` puts the UI rate back before the game quits and saves its options, so `options.ini`
never keeps it.

| Flag | What it does |
| --- | --- |
| `uncapped` | Draws as many frames as the machine can, as `--test` does; [running.md](running.md#why-it-is-fast-and-what-that-costs) explains why that's safe. |
| `clearWeather` | No cloud, fog or rain, at once and however the weather turns during the run: it stops the weather and sets the admin values of the climate's cloud, fog and precipitation floats to 0. Stopping the weather alone leaves fog to fade out over seconds. |
| `fastUI` | Draws the UI 120 times a second, the `uiRenderFPS` option's highest. The UI draws at its own rate and the frames in between show its last drawing, so a step that waits for the UI to draw (`Events.OnPostUIDraw`) waits less. |

The lighting rate stays the player's (`lightFPS`, 15 by default). `setLightingFPS` takes up to
120. At 60, with its lighting waits counted in passes, a screenshot run that waits on the lighting
at seven spots took 13 seconds instead of 19, but its shots changed: a clock change had less time
to darken the scene before the shot. At 120 the thread fell behind, and a sweep held for passes of
that rate left squares dark.

## Capture modes

A mode that takes screenshots builds its steps with `PZHarness.Capture`, from
`PZHarness/Capture.lua`, and the harness crops its shots after the run:

```lua
local Capture = require "PZHarness/Capture"

function Shots.capture(selection, done)
    local run = Capture.new("MyModShots")      -- the mode's MODE_MARK
    for _, name in ipairs(Capture.names(selection)) do
        local panel
        run:group(name)                         -- one of its MODE_GROUPS
        run:add(function()                      -- one step per tick
            panel = MyMod.Panel:new(100, 100)
            run:newBackdrop():addChild(panel)
        end)
        run:addMatted(name, function()          -- once it has drawn, on black then on white
            return { Capture.elementRegion(name .. "_panel", panel) }
        end)
        run:removeBackdrop()
    end
    run:run({ names = { mod = getText("Sandbox_MyMod") } }, done)
end
```

- Steps: `Capture.runSteps(steps, onDone, mark)` runs a step a tick; a step returns the ticks to
  wait, or a function polled until it returns true. A poll still waiting after ten seconds is
  logged as `<mark> WAIT gave up` and dropped, and onDone gets how many were. `run:run(data, done)`
  runs the run's steps. If a wait gave up it fails the run, as `run:fail(reason)` does (`<mark>
  FAIL: <reason>` and a quit without `DONE`), so the last good captures stay; otherwise it writes
  `<cachedir>/Lua/<mark>.json`, `data` with the screen's size, the shots and the groups, and calls
  `done()`. With `data` nil it writes nothing, for a mode whose screenshots are its output.
- Waits: `Capture.drawn(n)` until the UI has drawn `n` more times (the UI draws at its own rate,
  see `fastUI`), `Capture.zoomSettled()`, and `Capture.DRAW_FRAMES`, enough drawings or frames for
  a change to reach the screen.
- Shots: `run:addOpaque(name, regions)` saves the screen as `<mode>_<name>.png`;
  `run:addMatted(name, regions)` saves it on black and on white, as `<mode>_<name>_k.png` and
  `_w.png`, turning the backdrop and every element given to `run:tint(element)` black, then white.
  `regions()` runs once the shot is taken and returns `Capture.region(name, x, y, w, h)` or
  `Capture.elementRegion(name, element)` entries in UI units; each becomes `<name>.png` in the
  captures folder. `run:screenshot(file)` saves `<file>.png` without a region.
- `Capture.writeJson(file, value)` writes any Lua value as JSON to `<cachedir>/Lua/<file>`.
- Icon sheets: `run:addIconSheet(name, icons)` lays `icons` (a list of `{ name, texture }`, or a
  function returning one when the step runs) out on a backdrop at their own size and shoots them
  matted, each icon its own region `<icon name>.png`.
- Item and recipe names: `Capture.newCatalog(opts)` builds the entries a mod's pages are laid out
  from, in the game's language. `catalog:items(fullTypes)` gives `{ icon, name, fullType }` for each
  item; `catalog:recipes(prefix)` gives every craftRecipe and then every build menu recipe whose
  name starts with `prefix` (the `recipePrefix` test setting by default) as `{ id, name, skills,
  learn = { needed, magazines, auto, autoAll, research }, inputs, outputs, build }`, an input
  `{ items, count, keep, tag, uses, fluid or fills }`, a build menu recipe's `build` the `{ icon,
  name }` of what it builds; `catalog:recipe(name, build)` and `catalog:item(fullType, count)` give
  one. Icons are named `icon_<Module>_<Type>` for an item, the crafting window's icon, and
  `icon_build_<recipe>` for the build menu's; `catalog:iconList()` lists every icon the entries
  name so far, for `run:addIconSheet`. `opts.prefer` lists the full types an input that takes any
  item with a tag shows (as `PZHarness.Test.inputItem` picks), `opts.fluidContainers` the
  container, by fluid type, a line that takes or fills any container shows, and
  `opts.literature` the items whose names `learn.magazines` lists.

`lib/capture.py <cache dir> <mark> <captures folder>` turns a matted pair into alpha (a pixel
that reads k on black and w on white has alpha 1 - (w - k) and colour k / a), crops every region
and writes the rest of `<mark>.json` to the folder's `promo.json`, with the captures each group
made. Only the groups the run shot are replaced, and a group's captures it no longer makes go. A
mod with captures of its own defines `harness_after_<mode>` to run its own script, which imports
`Extraction` from it, saves its images with `save(image, group, name)` and calls `finish()`.

### Staging

`PZHarness.Stage`, from `PZHarness/Stage.lua`, holds what staging a world shot takes, and
`PZHarness/StageLots.lua` adds open ground and lots to it; its waits are runSteps waits and its
`add...` functions add steps to a run:

```lua
local Stage = require "PZHarness/Stage"
require "PZHarness/StageLots"

local lot
local groups = {
    yard = function()
        -- Looks around from the square (squares never seen draw dark), a step out from the closest zoom.
        Stage.addGoTo(run, getPlayer(), { Stage.lotSquare(lot, 2, 5) }, 1)
        run:addOpaque("yard", function()
            return { Stage.centred("yard", Stage.lotSquares(lot)) }  -- README-wide, the lot in the middle
        end)
    end,
}
Stage.runGroups(run, selection, groups, function(chosen)
    lot = Stage.findLot(getPlayer(), 4, 4, { trees = true })   -- nil fails the run with what's missing
    if not lot then return "open ground 4x4" end
    Stage.addWorldSettings(run, { hour = 12, origins = { Stage.lotSquare(lot, 0, 0) } })
    run:add(function()
        Stage.clearLotForShots(lot, 2)                           -- its trees and ground cover go
        Stage.placeTile(Stage.lotSquare(lot, 1, 1), "my_mod_tiles_0")
    end)
end, data, done)
```

- Finding and clearing: `closestSquare(player, accepts)` (within `SEARCH_RADIUS`, nearest first,
  then west, then north), `eachSquareAround(x, y, z, radius, fn)`, `removeTrees(x, y, z)` (within
  `TREE_RADIUS`: near a building a tree out of sight draws as a black silhouette),
  `isGroundCover(object)` and `clearGroundCover(square)` (grass, weeds, bushes and litter),
  `removeVehicles(x1, y1, x2, y2, z)`, and `silenceRadios(origins)`, as radio and television
  captions float over the shots.
- Open ground and lots (`PZHarness/StageLots.lua`): `isOpenGround(square, opts)` holds for a
  loaded square outdoors and in no room, on solid floor that isn't water, with no vehicle and
  nothing on it but floor and ground cover, nor a wall unless `allows` takes it. `opts`: `bare`
  (nothing but floor), `trees` (trees too), `allows(object)` (other objects too), `floor` (a prefix
  the floor's sprite name starts with: `NATURAL_FLOOR` for soil or grass) and `free` (nothing on it
  stops a character walking on, `IsoGridSquare.isFree`). `isAreaOpen(corner, w, h, accepts)` holds
  when `accepts` does for every square of the rectangle (nil for one not loaded).
  `findLot(player, w, h, opts)` is the closest lot `{ x, y, z, w, h }` (its north-west corner) of
  open ground with `opts`, or nil; `opts.others` lists lots it keeps `opts.gap` squares from, and
  `opts.clearance` squares round it must be open ground of any floor too, so no building or fence
  stands at its edge. `lotSquare(lot, dx, dy, up)` is a square of it (nil if not loaded),
  `lotSquares(lot)` all of them, as a framing takes them, and `recalcLot(lot)` recalculates it and
  the squares beside it, so that what was set on it draws.
- Tiles and clearing: `placeTile(square, sprite, modData)` places a tile at once on this side, as
  `PZHarness.Fixtures.newTile` does, and recalculates its neighbours so it draws (nothing removes
  it, unlike a test's `T.placeTile`); `clearToFloor(square, keeps)` takes every object but the
  floor and what `keeps(object)` accepts. `clearLot(lot, margin)` takes the trees and ground cover
  off the lot and `margin` squares round it, `clearLotForShots(lot, margin)` the trees within
  `TREE_RADIUS` too, and `emptyLot(lot)` takes the lot down to its floors, items lying there too,
  and recalculates it, for the next stage on the same lot.
- Seeing: `addLookAround(steps, player, square)` puts the character on the square's middle and turns
  it round at once, each facing held for a few lighting passes, then waits on
  `lightingSettled(player, change)`: no square newly seen and no light changed for 300 ms, and
  with `change` a change first, as a new hour or light takes most of a second to show.
  `addGoTo(run, player, squares, stepsOut)` looks around from each of `squares` the character
  hasn't looked around from yet in the run, then from the last, where it stays, and zooms
  `stepsOut` steps out from the closest.
- Zoom: `zoomOut(stepsOut)` sets the zoom that many steps out from the closest and returns the wait
  for it; `pushClosestZoom()` adds the 25% the game draws but the options leave out, without
  saving it, and `popClosestZoom()` takes it away.
- Framing, in UI units: `onScreen(square)` is its floor's centre, `screenBox(squares, top)` what
  they and their tiles cover (`top(square)` gives a taller reach than `TILE_TOP` at zoom 1).
  `centred(name, squares, opts)`, `rightAligned` (room on the left for a title) and the square
  `squareRegion` give regions `opts.width` (`WORLD_W`, the README's 1260, by default) wide kept on
  the screen, `cropped` just the squares, and `screenRegion(name, left, top, right, bottom)` any
  rectangle cut at the screen's edges; each reaches `CROP_MARGIN` past what it frames.
- The world: `addWorldSettings(run, { hour, wind, origins })` sets the hour, full colour (a fresh
  world's climate greys the picture by season), the climate's wind intensity, waiting until the
  wind blows, and silences the radios around `origins`; `addHour(run, hour)` turns the clock and
  waits for the lighting to follow.
- Interface shots, matted: `addWindowShot(run, name, { open, ready, near, close })` opens a window
  at 100, 100 on a backdrop (`near()`, a square, has the character stand beside it meanwhile, for
  a window that closes out of reach), and `addMenuShot(run, name, open)` a context menu, `open()`
  returning its menus, the top one first, their submenus opened with `openSubMenu(menu, name)`,
  vanilla's debug options hidden.
- `runGroups(run, selection, groups, prepare, data, done)` runs a capture mode's groups: it fails a
  selection that names a group `groups` lacks, calls `prepare(chosen)`, which finds and builds what
  the groups need and returns why it can't, hides the UI, puts the mouse in a corner, where the
  world outlines nothing and no menu follows it, adds each group's steps under `run:group`, logs
  `<mark> TIME <group> <seconds> s` for each and the total, and runs the run. For `prepare`,
  `groupNeeds(groups, chosen, key)` gives the set (name → true) of every name in the `key` list of
  each chosen group's entry in `groups`, so that a run looks only for what its groups need.
