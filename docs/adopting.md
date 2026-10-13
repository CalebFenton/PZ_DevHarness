# Adopting PZ_DevHarness

How a mod takes the harness on, what it tells the harness about itself, and the test library its tests use. The [README](../README.md) says what the harness is for; [running.md](running.md) covers the run script and [multiplayer.md](multiplayer.md) the `--mp` mode.

## Layout

| Path | What it is |
| --- | --- |
| `bin/run-client.sh` | The client runner behind a mod's `dev/run-debug-client.sh`, single player and multiplayer (`--mp`). |
| `bin/validate-server.sh` | Boots a throwaway dedicated server with the mod and fails on anything the mod logs. |
| `lib/harness.sh` | Paths, JVM arguments, the game lock, `install_mod`, `compile_java`, and the dedicated server both scripts start (`prepare_server`, `start_server`, `stop_server`, `server_problems`). A mod's own dev scripts may source it. |
| `java/ClickToStart.java` | Starts the client, presses "Click to start" on the loading screen and gives the asset loader more threads (`java/AssetLoading.java`). |
| `java/FastServer.java` | Starts the dedicated server of `--mp` and `validate-server.sh` with the same wider asset loader. |
| `mod/42/` | The harness mod (`cf_test_harness`): `client/PZHarness/Runner.lua`, `TestLib.lua`, `ServerCalls.lua` and `Leaks.lua`, the leak check between tests; `server/PZHarness/ServerHandlers.lua`, the server's half of the tests' server channel, and `ServerFixtures.lua`, the server's half of the two-sided fixtures; `shared/PZHarness/Fixtures.lua`, what both halves do, `Checks.lua`, expectations for server handlers, and `Snapshot.lua`, what the leak check reads on each side. |

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
| `CACHE_NAME` | Cache dirs go to `$TMPDIR/<name>-client`, `-server`, `-mpclient`, `-mpserver` and (by convention for the mod's own scripts) `-check`. |
| `TAG` | The console tag of the tests' lines, such as `MyModTest`. |
| `RELOAD_FILES` | A bash array of globs, relative to the dev mod, of the files a kept game loads again for a rerun, in load order (the mod's test library first). With `--mp` the server loads those under `media/lua/server` and `media/lua/shared` again too, so list the dev mod's server handler files here. |
| `MODES` | The mod's other modes, space-separated; each becomes a `--<mode>` flag. |
| `MODE_MARK_<mode>` | The console mark of the mode's lines; the run waits for `<mark> DONE`. |
| `MODE_SELECTION_<mode>` | Optional: the environment variable whose value the mode's handler gets as its selection, as `TESTS` is for `--test`. |
| `TEST_MAP` | Optional: a bash array of `'<glob>=<prefix>,<prefix>'` entries for `--test --changed`. Each glob is matched against the paths changed since `HEAD`, relative to the repository, with bash's `[[ == ]]`, where `*` crosses `/`; every entry a file matches adds its test name prefixes, and an empty list (`'<glob>='`) adds none. A changed file under the mod, the dev mod or the harness mod that no glob matches runs every test; files elsewhere run none. Leave files every test depends on unmatched. `--changed` refuses to run while a glob matches no file, and the runner fails a prefix that names no test, so a rename shows up in the map at once. |
| `PRECHECK` | Optional: a bash array, the command every game run of the harness runs first from the repository, such as the mod's Lua compile and static checks. If it fails, no game starts. |
| `QUIET_WORLD` | Optional: a bash array of `Key=value` sandbox options that make a `--test` world quiet, replacing the harness's list ([running.md](running.md#a-quiet-world)); `QUIET_WORLD=()` keeps the world's own population. |
| `SERVER_PROBLEMS` | Optional: an extended regex of server log lines that count as the mod's problems, besides stack traces through it. |
| `SERVER_IGNORE` | Optional: an extended regex of matching lines that don't count. |

Hooks, bash functions the conf may define:

| Hook | When it runs |
| --- | --- |
| `harness_check_<mode>` | Before the lock and the launch. `$SELECTION` holds the selection; exit nonzero to refuse it, so a typo fails at once. |
| `harness_after_<mode>` | After a run of the mode that finished cleanly, instead of the plain `PASS`, such as to post-process screenshots in `$CACHE/Screenshots`. |
| `harness_server_setup` | After a server's `$CACHE/Server/$SERVER_NAME.ini` is written: in `validate-server.sh`, and for the server of `--mp`, whose sandbox then gets `Zombies = 6` and the `QUIET_WORLD` options it doesn't set appended; add files such as `${SERVER_NAME}_SandboxVars.lua`. `$MP` is `1` for the `--mp` server. |

Hooks can read `$REPO`, `$CACHE`, `$MOD_DIR`, `$DEV_MOD_DIR` (absolute by then), `$MODE` and `$MP`.

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
    tests = {                     -- the test library's settings, all optional
        hour = 10,                -- tests run at this hour unless their spec gives one
        perks = { Perks.Electricity }, -- restored after every test
        sandbox = "MyMod",        -- SandboxVars.MyMod, which T.setSandbox tries first
        sandboxChanged = function() end, -- after T.setSandbox sets or restores an option
        setup = function(self, spec) end, -- before every spec.run; may push undos with T.defer
        recipePrefix = "MyMod_",  -- for T.recipeNames, T.learnRecipes, T.craftTest
        isFreeSquare = function(square, indoors) return square:isFree(false) end, -- for T.squares
        remove = function(object) return false end, -- true if it removed one of the mod's objects
        leakRadius = 32,          -- squares each way the leak check reads; past where T.squares looks by default
        leakLevels = { 0, 1 },    -- z levels the leak check reads; the character's own by default
        leakIgnore = { "^mymod_puddle" }, -- Lua patterns over "<sprite>@<class>" the leak check leaves out, past the built-in ones
    },
})
```

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
- Restore stack, two-sided (see [two-sided fixtures](multiplayer.md#two-sided-fixtures)): `defer`, `onTick`, `setTime`, `setPerk`, `setSandbox`, `setMultiplier`, `setGrid`, `makeDark`, `changeItem`; `spec.instant` and the `perks` setting too.
- Queue: `wait`, `waitUntil`, `step`. What a step queues runs right after it, in order (vanilla's adding-actions mode), and a clear of the queue inside it (`luautils.walkAdj`) drops only that. Any other clear of the queue while the test's own waits and steps are still in it, such as a timed action that turns invalid or is refused, fails the test at once with the action that was running, and validate doesn't run.
- The server: `server(self, name, args)` calls the dev mod's handler `name` and leaves its answer in `self.server[name]` exactly as the handler returned it, so `false`, `0` and `nil` arrive as themselves; `serverUntil(self, name, args, done, maxMs)` calls it until `done(reply)`; `give(self, name, items)`; `count(self, name, types, opts)`.
- Verdicts: `printVerdict(name, failures, seconds)` prints a test's PASS or FAIL line. The harness runner prints it once its leak check after the test is done ([running.md](running.md#leaks-and-desyncs)); the debug menu's runner gets it from validate.
- Squares and fixtures: `squares`, `track`; placed by the server: `placeTile`, `placeBench`, `placeVehicle`; placed and picked up by the character, as a player does with the moveables cursor: `placeAsPlayer(self, square, itemType, sprite, modData)` (a handle `{ x, y, z, square }`, `object` once this client has it, removed when the test ends) and `pickUpAsPlayer(self, handleOrSquare, sprite)`; this game only: `tile`, `placeMoveable`, `bench`, `vehicle`; `lineUpTrailer`.
- Crafting: `recipeNames`, `learnRecipes`, `forgetRecipes`, `recipeInputs`, `addRecipeInputs` (this game only), `inputItem(input, prefer)`, `placeWorkTable`, `craftRefusal`, `startCraft`. `inputItem` is the script item `recipeInputs` picks for one of a recipe's inputs: the first of its possible items named in `prefer`, else the first that isn't a generic `Base.Moveable`. Any test that starts a craft with `startCraft` and fails also reports why the game refused it, so a mod's own craft tests get that without `craftTest`.
- Lookups: `player`, `objectWithSprite`, `countPairs`; `PZHarness.Fixtures` has these and `vehicleById` for server handlers too, `ring(x, y, r)`, which iterates (`for sx, sy in ...`) over the squares at exactly `r` squares from x, y, each once, for a search that widens ring by ring from the nearest, and `teleportToMiddle(player, x, y, z)`: `teleportTo` alone leaves the character on the square's north-west corner, from where vanilla's `walkAdj` takes a square two to the north or west as in reach, walks nowhere, and an action that needs the square adjacent stops.

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
