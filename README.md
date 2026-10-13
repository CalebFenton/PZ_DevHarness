# PZ test harness

Runs a Project Zomboid Build 42 mod's in-game tests unattended on macOS, and any other unattended
job the mod defines (screenshots, measurements). It starts the game in debug mode without Steam,
with its own cache dir, the mod, the mod's dev mod and this repository's harness mod; starts the
mod's debug scenario; runs the tests with the vanilla timed action test runner's resets but none
of its pauses; prints the results; and quits. The mod owns every name and all content: its test
prefix, console tag, scenario, sandbox namespace, fixtures and extra modes.

## Layout

| Path | What it is |
| --- | --- |
| `bin/run-client.sh` | The client runner behind a mod's `dev/run-debug-client.sh`. |
| `bin/validate-server.sh` | Boots a throwaway dedicated server with the mod and fails on anything the mod logs. |
| `lib/harness.sh` | Paths, JVM arguments, the game lock, `install_mod`, `compile_java`. A mod's own dev scripts may source it. |
| `java/ClickToStart.java` | Starts the client, presses "Click to start" on the loading screen and gives the asset loader more threads. |
| `mod/42/` | The harness mod (`cf_test_harness`): `PZHarness/Runner.lua` and `PZHarness/TestLib.lua`. |

## Adopting it

The harness sits in the mod's repository at `dev/harness`:

```sh
git -c protocol.file.allow=always submodule add /Users/caleb/repos/pz-test-harness dev/harness
```

The mod then needs three things.

### `dev/harness.conf`

Sourced bash. Paths are relative to the repository. The mod's id and name come from its
`mod.info`, so they aren't repeated here.

| Key | Meaning |
| --- | --- |
| `MOD_DIR` | The published mod's folder, such as `Contents/mods/MyMod`. It is copied into the cache. |
| `DEV_MOD_DIR` | The dev mod's folder, such as `dev/MyModDevHarness`. It is linked into the cache. |
| `CACHE_NAME` | Cache dirs go to `$TMPDIR/<name>-client`, `-server` and (by convention for the mod's own scripts) `-check`. |
| `TAG` | The console tag of the tests' lines, such as `MyModTest`. |
| `RELOAD_FILES` | A bash array of globs, relative to the dev mod, of the files a kept game loads again for a rerun, in load order (the mod's test library first). |
| `MODES` | The mod's other modes, space-separated; each becomes a `--<mode>` flag. |
| `MODE_MARK_<mode>` | The console mark of the mode's lines; the run waits for `<mark> DONE`. |
| `MODE_SELECTION_<mode>` | Optional: the environment variable whose value the mode's handler gets as its selection, as `TESTS` is for `--test`. |
| `SERVER_PROBLEMS` | Optional: an extended regex of server log lines that count as the mod's problems, besides stack traces through it. |
| `SERVER_IGNORE` | Optional: an extended regex of matching lines that don't count. |

Hooks, bash functions the conf may define:

| Hook | When it runs |
| --- | --- |
| `harness_check_<mode>` | Before the lock and the launch. `$SELECTION` holds the selection; exit nonzero to refuse it, so a typo fails at once. |
| `harness_after_<mode>` | After a run of the mode that finished cleanly, instead of the plain `PASS`, such as to post-process screenshots in `$CACHE/Screenshots`. |
| `harness_server_setup` | In `validate-server.sh`, after it writes `$CACHE/Server/$SERVER_NAME.ini`; add files such as `${SERVER_NAME}_SandboxVars.lua`. |

Hooks can read `$REPO`, `$CACHE`, `$MOD_DIR`, `$DEV_MOD_DIR` (absolute by then) and `$MODE`.

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
        -- see "Capture settings".
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

## The test library

`PZHarness.Test`, from `PZHarness/TestLib.lua`:

- Registering: `test(name, spec)`, `craftTest(name, spec)`.
- Expectations: `expect`, `expectNear`, `need`.
- Restore stack: `defer`, `onTick`, `setTime`, `setPerk`, `setSandbox`, `setMultiplier`, `setGrid`, `makeDark`.
- Queue: `wait`, `waitUntil`, `step`.
- Squares and fixtures: `squares`, `track`, `tile`, `placeMoveable`, `bench`, `vehicle`, `lineUpTrailer`.
- Crafting: `recipeNames`, `learnRecipes`, `forgetRecipes`, `addRecipeInputs`, `placeWorkTable`, `craftRefusal`, `startCraft`. Any test that starts a craft with `startCraft` and fails also reports why the game refused it, so a mod's own craft tests get that without `craftTest`.
- Lookups: `player`, `objectWithSprite`, `countPairs`.

## Capture settings

Flags of a registered mode, for modes that take screenshots. They take effect just before `run`;
`done()` puts the UI rate back before the game quits and saves its options, so `options.ini`
never keeps it.

| Flag | What it does |
| --- | --- |
| `uncapped` | Draws as many frames as the machine can, as `--test` does; see below. |
| `clearWeather` | No cloud, fog or rain, at once and however the weather turns during the run: it stops the weather and sets the admin values of the climate's cloud, fog and precipitation floats to 0. Stopping the weather alone leaves fog to fade out over seconds. |
| `fastUI` | Draws the UI 120 times a second, the `uiRenderFPS` option's highest. The UI draws at its own rate and the frames in between show its last drawing, so a step that waits for the UI to draw (`Events.OnPostUIDraw`) waits less. |

The lighting rate stays the player's (`lightFPS`, 15 by default). `setLightingFPS` takes up to
120. At 60, with its lighting waits counted in passes, a screenshot run that waits on the lighting
at seven spots took 13 seconds instead of 19, but its shots changed: a clock change had less time
to darken the scene before the shot. At 120 the thread fell behind, and a sweep held for passes of
that rate left squares dark.

## Running

`dev/run-debug-client.sh`:

| Flags | What happens |
| --- | --- |
| none | Play by hand: the main menu, with the scenario under Scenarios and the tests under Debug menu > Dev > Unit Tests > Timed Actions. |
| `--test` | Runs every test of the mod and quits. Exits 1 on a failure or any Lua error. |
| `--test --stay` | The same, but the game stays open; the next `--test --stay` reruns the tests in it. |
| `--<mode>` | Runs the mod's handler for the mode and quits. |

Environment: `TESTS=<prefix>,...` runs only the tests whose names start with one of them;
`TIMEOUT` caps a run in seconds (default 1200); `CACHE` moves the cache dir; `JAVAC` names the
compiler for `ClickToStart.java` (any JDK from 8 on; the game's own Java has none); `PZ_APP`
names another game `Contents` folder.

Console lines, in `<cache>/console.txt`: `<TAG> START <n>`, `TEST: <name>`, `<TAG> PASS <name>`,
`<TAG> FAIL <name>: <reasons>`, `<TAG> TIME <s> s, <n> frames`, `<TAG> DONE passed=<n> failed=<n>`;
with `--stay` also `<TAG> RUN <id>` and `<TAG> IDLE ...`. The script prints every line with the
run's mark and exits 0 only if the run finished, nothing failed and no Lua error was logged.

## Why it is fast, and what that costs

- No pause between tests. The vanilla runner pauses a second after each test so you can read its
  result; the harness runs the same resets (full health, empty inventory, nothing worn or held,
  the build cheat off, the character back where the test started) and starts the next test on
  the next tick.
- Uncapped frames. Game time per second doesn't depend on the frame rate, so more frames a second
  only shorten what is counted in ticks. `--test` and modes registered `uncapped` draw as many
  frames as they can (about 260 a second on an M3 Max, against 60). A test therefore waits with
  `waitUntil` on the condition it needs, never for a fixed number of frames. Every mode loads
  uncapped, since the main menu and the loading screen step per frame; the others go back to 60
  when the scenario starts.
- More asset loader threads. The game loads textures, meshes and animations on 4 threads, and the
  loading screen waits about 8 seconds for them with all 4 busy. ClickToStart swaps in a pool of
  up to 12 (the cores less 4), which cuts that wait to about 2 seconds.
- Settling by loaded chunks. A run starts once one square in every chunk 40 squares around the
  character has loaded, not after a fixed delay.
- Fast UI in captures. A mode registered `fastUI` draws the UI at its highest rate, so its steps
  that wait for the UI to draw wait less.
- `--test --stay`. Starting and quitting the game costs about 21 seconds. A kept game reruns the
  tests in a second or two plus their own time: the runner unregisters the mod's tests, runs
  `RELOAD_FILES` again with `reloadLuaFile` and reruns. `reloadLuaFile` ignores a file's
  `Events.*.Add` calls (`LuaCompiler.rewriteEvents`), so only files that just register tests
  reload safely; a change to anything else in the dev mod, to the harness mod, or to the published
  mod restarts the game. What earlier runs left in the kept world stays there, so finish with a
  plain `--test`. The kept game shows and logs `<TAG> IDLE`, draws 24 frames a second while it
  waits, and quits after 10 minutes without a run or when another run needs the game.
- Early stop. In debug mode a Lua error stops the game in its error handler, so it never quits on
  its own. A stack trace through any of the three mods, or any Lua failure once the harness has
  started, ends the run at once and prints the trace.
- Silent. Harness runs set every volume in the cache's `options.ini` to 0; the sound engine still
  runs. Playing by hand keeps your volumes.

## Other behaviour

- One game at a time. Every script that starts a game, for any mod, takes the lock
  `$TMPDIR/pz-test-harness-game.lock` and waits while another holds it; a lock whose owner died
  is taken over. A kept `--stay` game holds the lock itself, and the next run that needs the game
  stops it, unless that run is a `--test --stay` of the same cache dir that can rerun in it.
- The published mod is copied into the cache's `mods` folder, not linked, and the cache dir is
  under the real path of `$TMPDIR`: the game reads tile depth maps by absolute path and refuses
  paths through a symlink (`ZomboidFileSystem.validatePrefix`). The dev mod and the harness mod
  have no tiles and are linked.
- The runner reads the run from `<cache>/Lua/PZHarness.txt` and rerun requests from
  `<cache>/Lua/PZHarnessRerun.txt`. Without the first file, as in a game the script didn't start,
  there is no mode, and the tests print under the tag `PZHarness`.
- `debug-options.ini` sets `DebugScenario.ForceLaunch` in harness modes, so the scenario the
  runner marks `forceLaunch` starts from the main menu, and the runner turns off pausing when the
  window loses focus.
- A run takes keyboard focus while its window is up, and a keypress there (Escape opens the pause
  menu) can break it, so leave it alone until it quits.
- Each mode's run deletes the `<mode>_*.png` screenshots in `<cache>/Screenshots` before it
  starts, so name a mode's screenshots after it.
