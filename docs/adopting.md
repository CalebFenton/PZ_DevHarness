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
| `java/ClickToStart.java` | Starts the client, presses "Click to start" on the loading screen and gives the asset loader more threads (`java/AssetLoading.java`). |
| `java/FastServer.java` | Starts the dedicated server of `--mp` and `validate-server.sh` with the same wider asset loader. |
| `mod/42/` | The harness mod (`cf_test_harness`): `client/PZHarness/Runner.lua`, `TestLib.lua`, `ServerCalls.lua` and `Leaks.lua`, the leak check between tests, and `Capture.lua`, the steps and shots of [capture modes](#capture-modes); `server/PZHarness/ServerHandlers.lua`, the server's half of the tests' server channel, and `ServerFixtures.lua`, the server's half of the two-sided fixtures; `shared/PZHarness/Fixtures.lua`, what both halves do, `Checks.lua`, expectations for server handlers, and `Snapshot.lua`, what the leak check reads on each side. |

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
| `CACHE_NAME` | Cache dirs go to `$TMPDIR/<name>-client`, `-server`, `-mpclient`, `-mpserver` and `-check` (the static check). |
| `TAG` | The console tag of the tests' lines, such as `MyModTest`. |
| `RELOAD_FILES` | A bash array of globs, relative to the dev mod, of the files a kept game loads again for a rerun, in load order (the mod's test library first). With `--mp` the server loads those under `media/lua/server` and `media/lua/shared` again too, so list the dev mod's server handler files here. |
| `MODES` | The mod's other modes, space-separated; each becomes a `--<mode>` flag. |
| `MODE_MARK_<mode>` | The console mark of the mode's lines; the run waits for `<mark> DONE`. |
| `MODE_SELECTION_<mode>` | Optional: the environment variable whose value the mode's handler gets as its selection, as `TESTS` is for `--test`. |
| `MODE_GROUPS_<mode>` | Optional: the groups a [capture mode](#capture-modes) shoots, space-separated, in the order a run takes them. The selection may name only these, or the run fails before the game starts and lists them; the handler gets the named ones, or every group if the selection names none, comma-separated in this order. |
| `MODE_CAPTURES_<mode>` | Optional: the folder, such as `art/promo/captures`, that a [capture mode](#capture-modes)'s shots are cropped into after a run that finished cleanly. |
| `TEST_MAP` | Optional: a bash array of `'<glob>=<prefix>,<prefix>'` entries for `--test --changed`. Each glob is matched against the paths changed since `HEAD`, relative to the repository, with bash's `[[ == ]]`, where `*` crosses `/`; every entry a file matches adds its test name prefixes, and an empty list (`'<glob>='`) adds none. A changed file under the mod, the dev mod or the harness mod that no glob matches runs every test; files elsewhere run none. Leave files every test depends on unmatched. `--changed` refuses to run while a glob matches no file, and the runner fails a prefix that names no test, so a rename shows up in the map at once. |
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
| `perks` | client | Perks (`Perks.Electricity`) restored after every test, however it changed them; the server's copy too. |
| `sandbox` | both | The mod's table in `SandboxVars`, which `setSandbox` tries before the game's options. |
| `sandboxChanged()` | both | Called on each side after its copy of a sandbox option is set or restored, for state the mod derives from its options. |
| `setup(self, spec)` | client | Called before every `spec.run`, after its hour and sandbox options; may push undos with `defer`. |
| `recipePrefix` | client | The name prefix of the mod's craftRecipes, for `recipeNames`, `learnRecipes`, `craftTest`. |
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

The runner records the three mods for the scenario's new save and turns zombies off, so a
scenario's own `setSandbox`, which runs after, only sets what the mod needs.

The mod's test library inherits the shared one and adds its fixtures:

```lua
require "PZHarness/TestLib"
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

A handler that checks many things on the server collects what it found wrong with
`PZHarness.Checks.new()`, from `PZHarness/Checks.lua`, and answers with the list for the test to
report. It returns `expect, expectNear, failures`: `expect` and `expectNear` work as the test
library's do, and fill `failures`:

```lua
require "PZHarness/Checks"

PZHarness.serverHandler("thingsStocked", function()
    local expect, expectNear, failures = PZHarness.Checks.new()
    expect(MyMod.stock ~= nil, "no stock table")
    expectNear("the stock's weight", MyMod.stockWeight(), 2.5)
    return { failures = failures }
end)
```

## The test library

`PZHarness.Test`, from `PZHarness/TestLib.lua`:

- Registering: `test(name, spec)`, `craftTest(name, spec)`. `spec.spOnly` or `spec.mpOnly`, a reason string, keeps a test out of the other mode. A test still busy after 30 seconds of real time fails with what it was waiting on (the queued action's type, or which server answer or wait; `waitUntil(condition, maxFrames, what)` names a wait), its queue is cleared, its undos run and the next test starts; `spec.timeoutSeconds` raises the limit for a test that is slow on purpose. A test whose starting square still hasn't loaded, some seconds after the test before it took the character far away, fails without running, and the next one waits for the square again.
- Expectations: `expect`, `expectNear`, `need`. Once a test misses something, its later queued steps and waits don't run.
- Restore stack, two-sided (see [two-sided fixtures](multiplayer.md#two-sided-fixtures)): `defer`, `onTick`, `setTime`, `setPerk`, `setSandbox`, `setMultiplier`, `setGrid`, `setMechanicsCheat`, `makeDark`, `changeItem`; `spec.instant` and the `perks` setting too. A multiplayer server times every action in real time, and an instant vehicle part install or uninstall on a client stops as invalid once the server has moved the part, so a test turns `setMechanicsCheat` on around those instead. Vanilla's `ISInstallVehiclePart:new` takes its time from its caller and never asks its `getDuration`, so neither cheat shortens an install: `shortenQueuedInstalls()`, in the step that queued one (`ISVehiclePartMenu.onInstallPart`), gives it the time `getDuration` gives.
- Queue: `wait`, `waitUntil`, `step`. What a step queues runs right after it, in order (vanilla's adding-actions mode), and a clear of the queue inside it (`luautils.walkAdj`) drops only that. Any other clear of the queue while the test's own waits and steps are still in it, such as a timed action that turns invalid or is refused, fails the test at once with the action that was running, and validate doesn't run.
- The server: `server(self, name, args)` calls the dev mod's handler `name` and leaves its answer in `self.server[name]` exactly as the handler returned it, so `false`, `0` and `nil` arrive as themselves; `serverUntil(self, name, args, done, maxMs)` calls it until `done(reply)`; `give(self, name, items)`; `count(self, name, types, opts)`; `batch(fn)` sends the calls `fn` queues back to back in one round trip ([multiplayer.md](multiplayer.md#the-server-channel)).
- Verdicts: `printVerdict(name, failures, seconds)` prints a test's PASS or FAIL line. The harness runner prints it once its leak check after the test is done ([running.md](running.md#leaks-and-desyncs)); the debug menu's runner gets it from validate.
- Squares and fixtures: `squares`, `track`; placed by the server: `placeTile`, `placeBench`, `placeVehicle`; placed and picked up by the character, as a player does with the moveables cursor: `placeAsPlayer(self, square, itemType, sprite, modData)` (a handle `{ x, y, z, square }`, `object` once this client has it, removed when the test ends) and `pickUpAsPlayer(self, handleOrSquare, sprite)`; this game only: `tile`, `placeMoveable`, `bench`, `vehicle`; `lineUpTrailer`.
- Crafting: `recipeNames`, `learnRecipes`, `forgetRecipes`, `recipeInputs`, `addRecipeInputs` (this game only), `inputItem(input, prefer)`, `placeWorkTable`, `craftRefusal`, `startCraft`. `inputItem` is the script item `recipeInputs` picks for one of a recipe's inputs: the first of its possible items named in `prefer`, else the first that isn't a generic `Base.Moveable`. Any test that starts a craft with `startCraft` and fails also reports why the game refused it, at the start or, for a craft it queued and then dropped, at perform, so a mod's own craft tests get that without `craftTest`.
- Lookups: `player`, `objectWithSprite`, `countPairs`; `PZHarness.Fixtures` has these and `vehicleById` for server handlers too, `ring(x, y, r)`, which iterates (`for sx, sy in ...`) over the squares at exactly `r` squares from x, y, each once, for a search that widens ring by ring from the nearest, and `teleportToMiddle(player, x, y, z)`: `teleportTo` alone leaves the character on the square's north-west corner, from where vanilla's `walkAdj` takes a square two to the north or west as in reach, walks nowhere, and an action that needs the square adjacent stops.
- Building and removing in a server handler, as the library's own fixtures do on either side (`PZHarness.Fixtures`): `newTile(square, sprite, modData)`, `newBench(square, entity, sprite, player)` (the bench, or nil and what is missing), `freeAdjacentSquare(here, used)`, and `removePlaced(thing)`, which removes an object through the `remove` setting, else the vanilla way, or a vehicle permanently; a server sends each to its clients.
- Walking: `standNextTo(square)` puts the character where vanilla's `walkAdj` would walk it, facing `square`, so the walk a menu option or an action queues first has no way to go and the turn an action's `waitToStart` waits for (`faceThisObject`, `shouldBeTurning`) is already done; walking and turning take real time, which neither the instant cheat nor the frame rate shortens. `placeAsPlayer` and `pickUpAsPlayer` do it themselves. `goNextTo(self, square)` queues the same, then waits until a multiplayer server has had the character there for a moment: the server learns it moved only from the client's position updates, and older ones still on their way (the runner's move to the test's start among them) can move it back, so an instant action's `complete()` can find it elsewhere. A test that queues an action whose `complete()` checks the character's reach goes there this way.

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

`lib/capture.py <cache dir> <mark> <captures folder>` turns a matted pair into alpha (a pixel
that reads k on black and w on white has alpha 1 - (w - k) and colour k / a), crops every region
and writes the rest of `<mark>.json` to the folder's `promo.json`, with the captures each group
made. Only the groups the run shot are replaced, and a group's captures it no longer makes go. A
mod with captures of its own defines `harness_after_<mode>` to run its own script, which imports
`Extraction` from it, saves its images with `save(image, group, name)` and calls `finish()`.
