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
| `bin/run-client.sh` | The client runner behind a mod's `dev/run-debug-client.sh`, single player and multiplayer (`--mp`). |
| `bin/validate-server.sh` | Boots a throwaway dedicated server with the mod and fails on anything the mod logs. |
| `lib/harness.sh` | Paths, JVM arguments, the game lock, `install_mod`, `compile_java`, and the dedicated server both scripts start (`prepare_server`, `start_server`, `stop_server`, `server_problems`). A mod's own dev scripts may source it. |
| `java/ClickToStart.java` | Starts the client, presses "Click to start" on the loading screen and gives the asset loader more threads. |
| `mod/42/` | The harness mod (`cf_test_harness`): `client/PZHarness/Runner.lua`, `TestLib.lua` and `ServerCalls.lua`; `server/PZHarness/ServerHandlers.lua`, the server's half of the tests' server channel, and `ServerFixtures.lua`, the server's half of the two-sided fixtures; `shared/PZHarness/Fixtures.lua`, what both halves do. |

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
| `CACHE_NAME` | Cache dirs go to `$TMPDIR/<name>-client`, `-server`, `-mpclient`, `-mpserver` and (by convention for the mod's own scripts) `-check`. |
| `TAG` | The console tag of the tests' lines, such as `MyModTest`. |
| `RELOAD_FILES` | A bash array of globs, relative to the dev mod, of the files a kept game loads again for a rerun, in load order (the mod's test library first). With `--mp` the server loads those under `media/lua/server` and `media/lua/shared` again too, so list the dev mod's server handler files here. |
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
| `harness_server_setup` | After a server's `$CACHE/Server/$SERVER_NAME.ini` is written: in `validate-server.sh`, and for the server of `--mp`, whose sandbox then gets `Zombies = 6` appended; add files such as `${SERVER_NAME}_SandboxVars.lua`. `$MP` is `1` for the `--mp` server. |

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

What only the authority can do goes in the dev mod's server Lua, as named handlers that tests call
with `T.server` (see [Multiplayer](#multiplayer)):

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

## The test library

`PZHarness.Test`, from `PZHarness/TestLib.lua`:

- Registering: `test(name, spec)`, `craftTest(name, spec)`. `spec.spOnly` or `spec.mpOnly`, a reason string, keeps a test out of the other mode.
- Expectations: `expect`, `expectNear`, `need`. Once a test misses something, its later queued steps and waits don't run.
- Restore stack, two-sided (see [Two-sided fixtures](#two-sided-fixtures)): `defer`, `onTick`, `setTime`, `setPerk`, `setSandbox`, `setMultiplier`, `setGrid`, `makeDark`, `changeItem`; `spec.instant` and the `perks` setting too.
- Queue: `wait`, `waitUntil`, `step`. What a step queues runs right after it, in order (vanilla's adding-actions mode), and a clear of the queue inside it (`luautils.walkAdj`) drops only that.
- The server: `server(self, name, args)` calls the dev mod's handler `name` and leaves its answer in `self.server[name]`; `serverUntil(self, name, args, done, maxMs)` calls it until `done(reply)`; `give(self, name, items)`; `count(self, name, types, opts)`.
- Squares and fixtures: `squares`, `track`; placed by the server: `placeTile`, `placeBench`, `placeVehicle`; this game only: `tile`, `placeMoveable`, `bench`, `vehicle`; `lineUpTrailer`.
- Crafting: `recipeNames`, `learnRecipes`, `forgetRecipes`, `recipeInputs`, `addRecipeInputs` (this game only), `placeWorkTable`, `craftRefusal`, `startCraft`. Any test that starts a craft with `startCraft` and fails also reports why the game refused it, so a mod's own craft tests get that without `craftTest`.
- Lookups: `player`, `objectWithSprite`, `countPairs`; `PZHarness.Fixtures` has these and `vehicleById` for server handlers too.

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
| `--test --mp` | The same in multiplayer: a dedicated server and a client that joins it; see [Multiplayer](#multiplayer). |
| `--test --mp --stay` | Both stay open; the next `--test --mp --stay` reruns the tests in them. |
| `--<mode>` | Runs the mod's handler for the mode and quits. |

Environment: `TESTS=<prefix>,...` runs only the tests whose names start with one of them;
`TIMEOUT` caps a run in seconds (default 1200); `CACHE` moves the cache dir (with `--mp` the
client's; `SERVER_CACHE` the server's); `SERVER_PORT` moves the `--mp` server off 16361 (it also
takes the next port); `JAVAC` names the compiler for `ClickToStart.java` (any JDK from 8 on; the
game's own Java has none); `PZ_APP` names another game `Contents` folder.

Console lines, in `<cache>/console.txt`: `<TAG> START <n>`, `TEST: <name>`, `<TAG> PASS <name>`,
`<TAG> FAIL <name>: <reasons>`, `<TAG> SKIP <name>: <why>` for each test that opted out of this
mode, `<TAG> TIME <s> s, <n> frames`, `<TAG> DONE passed=<n> failed=<n> skipped=<n>`; with
`--stay` also `<TAG> RUN <id>` and `<TAG> IDLE ...`. With `--mp` the server's log
(`<server cache>/server-console.txt`) gets `<TAG> SERVER FAIL <test>: <error>` for a handler or
undo that failed, and `<TAG> RUN <id>` for a rerun. The script prints every line with the run's
mark and both logs' paths, and exits 0 only if the run finished, at least one test passed, nothing
failed and no Lua error was logged on either side.

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
  `Events.*.Add` calls (`LuaCompiler.rewriteEvents`), so only files that just register tests or
  server handlers reload safely; a change to anything else in the dev mod, to the harness mod, or
  to the published mod restarts the game. What earlier runs left in the kept world stays there, so
  finish with a plain `--test`. The kept game shows and logs `<TAG> IDLE`, draws 24 frames a second
  while it waits, and quits after 10 minutes without a run or when another run needs the game.
- Early stop. In debug mode a Lua error stops the game in its error handler, so it never quits on
  its own. A Lua stack trace through any of the three mods, or any Lua failure once the harness
  has started, ends the run at once and prints the trace. An exception the game logs and goes on
  from (its frames indented twice), and anything on a server, which never stops at an error, fail
  the run in the scan after it instead.
- Silent. Harness runs set every volume in the cache's `options.ini` to 0; the sound engine still
  runs. Playing by hand keeps your volumes.

## Multiplayer

`--test --mp` takes the lock once, then:

1. Prepares two cache dirs, `$TMPDIR/<CACHE_NAME>-mpserver` and `-mpclient`, each with a copy of
   the mod and links to the harness mod and the dev mod.
2. Writes the server's `harness.ini` (the three mods, ports 16361 and 16362, `Open`, `PauseEmpty`
   off) and runs the conf's `harness_server_setup`, then appends `Zombies = 6` to its sandbox, so
   the world has no zombies, as the scenarios' do. Every cold run starts a new world.
3. Starts the server, through `start_server` in `lib/harness.sh` as `validate-server.sh` does,
   and the client with ClickToStart at the same time. The client waits at the main menu until the
   script writes `<client cache>/Lua/PZHarnessConnect.txt`, once the server's log says it started,
   then joins as the server's admin: a `-debug` client must have the ConnectWithDebug capability.
   Overlapping the boots saves about 8 seconds a run (the server boots slower while the client
   does, 18 seconds instead of 14); joining before the server listens would only fail.
4. The runner skips character creation (the default unemployed survivor), takes the character to
   the scenario's `startLoc`, waits for the world to load, runs the scenario's `onStart` and the
   mod's on the client, and runs the tests as in single player.
5. After `DONE` the server gets `quit` on its console and saves while the client quits; the script
   scans the client's log as in single player and the server's up to its exit as
   `validate-server.sh` does, plus stack traces through the dev mod and the harness mod and
   `SERVER FAIL` lines. Both processes stop on any exit of the script.

A cold run takes about 44 seconds on an M3 Max: 18 for the server to start (the client boots
meanwhile), 7 to join, 11 to load the world and reach the start, then the tests, then 7 for the
server to save and exit. A rerun in a kept `--mp --stay` game takes under a second plus the tests:
the server first loads its share of `RELOAD_FILES` again (the dev mod's `media/lua/server` and
`media/lua/shared` files) and marks the run in its log, then the client loads its files and
reruns. A change to any other file restarts both, as does either process having stopped. The kept
client quits after its idle time and the server goes with it; the lock is free once both have.

### The server channel

Tests are written once and run in both modes. On a multiplayer client the character, its
inventory and the world are the client's copies, and the mod's server Lua (which usually returns
early when `isClient()`) is empty, so what only the authority can do goes through `T.server`:

- `PZHarness.serverHandler(name, fn)` in the dev mod's server Lua registers `fn(player, args,
  defer)`, which returns a table of plain values (or nil and what is missing). `player` is the
  server's copy of the calling character. `defer(undo)` takes back what it built when the calling
  test ends, on the server, in order with the test's own undos; a handler that fails has its undos
  run at once.
- `T.server(self, name, args)` queues the call and a wait for its answer, which lands in
  `self.server[name]`. `args` may be a function of `self`, called when the call goes out, to use an
  earlier answer. A failed or missing answer fails the test as `T.need` does and drops the steps
  queued after it.
- Single player calls the handler in the same Lua state, at once. Multiplayer sends a client
  command (module `PZHarness`) and the server answers with a server command a tick or more later;
  an answer lost for 15 seconds fails the call. The runner starts the next test only once every
  request of the last one, its undos above all, has its answer, so no test meets what the one
  before built. An undo the server reports failed after the verdict prints its own `FAIL` line and
  counts in `DONE`.

A test that can't run in one mode says why: `spOnly = "<why>"` or `mpOnly = "<why>"` in its spec.
The runner skips it in the other mode and prints `<TAG> SKIP <name>: single player only: <why>`
(or `multiplayer only`). A missing reason, or both fields, fails the test in every mode.

### Two-sided fixtures

The library's fixtures act on both copies, so a test written once runs in both modes and single
player behaves as before:

- Setters (`setSandbox`, `setTime`, `setMultiplier`, `setGrid`, `setPerk`, `changeItem`, the
  test's `instant` and `perks`) change this game's copy at once; on a multiplayer client they also
  send the change to the server (handlers named `PZHarness.*` in `ServerFixtures.lua`) at once and
  queue a wait for its answer, so actions queued after them start once the server has it. The
  server undoes it when the test ends. A dev mod's server Lua sets
  `PZHarness.serverSettings.sandboxChanged` for what the client's `tests.sandboxChanged` does.
- Items: `T.give(self, name, items)` (`{ type, count, uses, condition, modData, worn, equip }`)
  makes them on the server, which sends them; once this client has them it puts them on and in
  hand (`PZHarness.dress`: clothing synced before its item reaches the client as a stray copy),
  and `self.items[name]` holds this client's copies. A dev mod's handler gives its own items with
  `PZHarness.giveItem(player, item, { worn, equip })` and lists the results as `given` in its
  reply; `T.server` then does the same. `T.count` counts the server's inventory.
- World: `placeTile`, `placeBench` and `placeVehicle` place on the server and return a handle at
  once whose `.object` (`.vehicle`) is this client's copy after a queued wait; the server removes
  them when the test ends, through `PZHarness.serverSettings.remove(object)` if set.
  `PZHarness.serverSettings.spawnVehicle(script, square, facing, args)` may make the vehicles.
  `T.placeWorkTable`, `T.learnRecipes` and `T.forgetRecipes` work outside tests too, as in a
  scenario's onStart; `PZHarness.ServerCalls.callOutsideTest(name, args, onReply)` calls any
  handler there.
- The runner resets the server's copy of the character before every test too, and after the
  scenario's and the mod's onStart copies the client's perk levels and known recipes to it.

### What a client can and can't do

- Client Lua runs on the client only: setting `SandboxVars`, the clock, the game speed or the grid
  directly changes the client's copy, which the server overwrites or ignores; use the setters
  above. The server's own sandbox at start comes from `harness_server_setup`.
- Objects a client places with `AddTileObject` (`T.tile`, `T.bench`) exist on that client only,
  and items it adds to the inventory aren't on the server: a timed action with `complete()` runs on
  the server, which can't find them. `ActionManager.sendAction` then logs "Unable to resolve
  container location", which fails the run. Use the two-sided fixtures or a server handler.
- An action's `complete()` runs on the server, and what it removes (an item the action used) can
  reach the client before the action ends there; an `isValid()` that then fails stops the action,
  and `ISBaseTimedAction:stop` empties the whole action queue, dropping the test's later steps.
- The server never sends a client the recipes it forgets (`SyncPlayerFieldsPacket`), and the game
  deletes a drainable item whose uses run out (`DrainableComboItem.update`).
- Commands through `sendClientCommand`, the Global Object System's syncs to the client's copies,
  and timed actions without `complete()` (such as the harness's own waits) work as in a real game.
- The client is admin, so permission checks the server makes for players aren't exercised.
- `getUsername()` of the client's character can differ from the account (`admin`) the server sees;
  don't key on it.

### Known noise and limits

- Joining resets the client's Lua (`Core.ResetLua`), so every mod's Lua loads twice on the
  client: once at boot, as in single player, and once as a multiplayer client. Load-time side
  effects outside Lua (files, Java state) happen twice. The reset also logs a
  `NoSuchFileException` for each mod without `media/AnimSets`; vanilla's, harmless, and not
  counted.
- The client doesn't pause when it loses focus, but like any run it takes keyboard focus while its
  window is up.
- Only `--test` runs in multiplayer; the mod's other modes are single player.

## Other behaviour

- One game at a time. Every script that starts a game, for any mod, takes the lock
  `$TMPDIR/pz-test-harness-game.lock` and waits while another holds it; a lock whose owner died
  is taken over. A kept `--stay` game (with `--mp` its client and server) holds the lock itself,
  and the next run that needs the game stops it, unless that run is a `--stay` run of the same
  cache dir that can rerun in it.
- The published mod is copied into the cache's `mods` folder, not linked, and the cache dir is
  under the real path of `$TMPDIR`: the game reads tile depth maps by absolute path and refuses
  paths through a symlink (`ZomboidFileSystem.validatePrefix`). The dev mod and the harness mod
  have no tiles and are linked.
- The runner reads the run from `<cache>/Lua/PZHarness.txt`, rerun requests from
  `<cache>/Lua/PZHarnessRerun.txt` and, with `--mp`, the server to join from
  `<cache>/Lua/PZHarnessConnect.txt`. Without the first file, as in a game the script didn't
  start, there is no mode, and the tests print under the tag `PZHarness`.
- `debug-options.ini` sets `DebugScenario.ForceLaunch` in single player harness modes, so the
  scenario the runner marks `forceLaunch` starts from the main menu, and the runner turns off
  pausing when the window loses focus.
- A run takes keyboard focus while its window is up, and a keypress there (Escape opens the pause
  menu) can break it, so leave it alone until it quits.
- Each mode's run deletes the `<mode>_*.png` screenshots in `<cache>/Screenshots` before it
  starts, so name a mode's screenshots after it.
