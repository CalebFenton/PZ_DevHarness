# Running tests and modes

What `dev/run-debug-client.sh` does with each flag, why a run is fast, and the rules every run follows. [debugging.md](debugging.md) says which run to reach for when.

## Flags and environment

`dev/run-debug-client.sh`:

| Flags | What happens |
| --- | --- |
| none | Play by hand: the main menu, with the scenario under Scenarios and the tests under Debug menu > Dev > Unit Tests > Timed Actions. |
| `--test` | Runs every test of the mod and quits. Exits 1 on a failure or any Lua error. |
| `--test --stay` | The same, but the game stays open; the next `--test --stay` reruns the tests in it. |
| `--test --mp` | The same in multiplayer: a dedicated server and a client that joins it; see [multiplayer.md](multiplayer.md). |
| `--test --mp --stay` | Both stay open; the next `--test --mp --stay` reruns the tests in them. |
| `--test --failed` | Runs only the tests that failed in the last `--test` run of the same kind (with or without `--mp`), and the one a stopped run was in. |
| `--test --changed` | Runs the tests the conf's `TEST_MAP` gives for the files changed since `HEAD`, staged, unstaged or untracked, and prints each file's share and why. A changed file under the mods that no glob covers runs every test; with nothing changed under the mods, nothing runs. |
| `--<mode>` | Runs the mod's handler for the mode and quits. |

`--failed` and `--changed` combine with `--mp` and `--stay`, not with each other or with `TESTS`.

Environment: `TESTS=<prefix>,...` runs only the tests whose names start with one of them, and
`=<name>` in the list names one test exactly; `REPEAT=<n>` runs the selection n times over in one
game and ends with a `<TAG> REPEAT <name> passed=<n> failed=<n>` line per test, the most failed
first; `ORDER=reverse` runs the tests in reverse order, and `ORDER=shuffle` in an order from a
seed the script picks and prints, which `ORDER=shuffle:<seed>` repeats; `LEAKS=fail` (the
default), `warn` or `off` sets what the [leak check](#leaks-and-desyncs) does; `TIMEOUT` caps a
run in seconds (default 300 for `--test`, times `REPEAT`, enough for a cold `--mp` run of a
whole suite, so it only catches a game that died; 1200 for the other modes); `CACHE` moves the
cache dir (with `--mp` the client's; `SERVER_CACHE` the server's); `SERVER_PORT` moves the
`--mp` server off 16361 (it also takes the next port); `JAVAC` names the compiler for
`ClickToStart.java` (any JDK from 8 on; the game's own Java has none); `PZ_APP` names another
game `Contents` folder.

Console lines, in `<cache>/console.txt`: `<TAG> START <n>`, `<TAG> ORDER <order>` and
`<TAG> REPEAT <n> rounds` when set, `<TAG> LEAKS <mode>`, `TEST: <name>`, `<TAG> LEAK <name>: <what>`
and `<TAG> DESYNC <name>: <square> client [...] server [...]` for what a test left behind,
`<TAG> PASS <name>`, `<TAG> FAIL <name>: <reasons>`, `<TAG> SKIP <name>: <why>` for each test that
opted out of this mode, each of those three ending with the test's wall time, `(<s> s)`; then the
`REPEAT` counts, `<TAG> SLOWEST` lines, `<TAG> TIME <s> s, <n> frames`,
`<TAG> DONE passed=<n> failed=<n> skipped=<n>`; with `--stay` also `<TAG> RUN <id>`,
`<TAG> DIRTY <name>: <what>` for what the last run in the kept game left behind, and
`<TAG> IDLE ...`. With `--mp` the server's log (`<server cache>/server-console.txt`) gets
`<TAG> SERVER FAIL <test>: <error>` for a handler or undo that failed, and `<TAG> RUN <id>` for a
rerun. The script prints every line with the run's mark and both logs' paths, and exits 0 only if
the run finished, at least one test passed, nothing failed and no Lua error was logged on either
side.

## A quiet world

A `--test` world doesn't populate itself: the world normally fills in a chunk or a building the
first time it loads, at random, and in the middle of a run that can put a generator, a crash
site or a parked car beside a test that never placed one, and make one run differ from the next.
`QUIET_WORLD` in `lib/harness.sh` lists the sandbox options that stop it, each with the vanilla
code it turns off: generator spawning, survivor houses and other building stories, vehicle and
zone stories, ranches, animal tracks and paths, rats and cockroaches, parked and jammed cars,
annotated maps (each of which makes a building a stash), house alarms, the helicopter and the
random meta events. In single player the runner sets them before the scenario's `setSandbox`,
which runs after and may set any of them back; on the `--mp` server they are appended to its
sandbox file wherever the conf's `harness_server_setup` set nothing. A conf that sets
`QUIET_WORLD` itself replaces the list. Other modes (`--promo`, `--art`, a mod's reports) and
`validate-server.sh` keep the world's own population.

## Leaks and desyncs

Between tests, and after the last, the runner resets the character and takes a snapshot of the
world around it (`shared/PZHarness/Snapshot.lua`), which it compares with the one from before the
test that just ended: the objects on every square within the `leakRadius` setting (by default a
little past where `T.squares` looks) on the `leakLevels` z levels (the character's own by
default), each as its sprite or item type and class, with generators and light switches on or
off; the vehicles there; whether a sparse grid of those squares has power; the character's perk
levels, known recipes and what it holds after the reset; where it starts; the sandbox options;
the grid; the game speed; the climate's admin overrides; and the clock, which may only have run
on.

The comparison leaves out objects the world changes by itself, and grass, which goes from a
square something was placed on and never comes back: crops and garden plants, erosion's grass,
plants, trees, bushes, cracks and roof snow, and grass overlays (`Snapshot.DEFAULT_IGNORE`). The
dev mod's `leakIgnore` setting adds Lua patterns, matched against `<sprite>@<class>`. A square
whose objects differ only by those doesn't count.

In multiplayer the server snapshots its copy ("PZHarness.snapshot") while the client snapshots
its own, and the server's differences are the ones reported for objects, vehicles, perks, recipes
and the clock, since the client only copies those from it. The client reports its own state (what
it holds, the power it works out itself, the options) and compares its squares with the server's
wherever either side saw one change. What the server sent can still be on its way, so a
difference between the copies, or a change of the client's own state, costs a second look half a
second later, and only what is still there is reported.

Each difference prints a `LEAK` line (the server's start with "on the server"), and each square
where the copies still differ a `DESYNC` line, at most a handful per test with a count of the
rest, before the test's verdict. With `LEAKS=fail` they fail the test, as its reasons; with
`LEAKS=warn` they only print; `LEAKS=off` skips the snapshots. A check that finds nothing costs one
snapshot, taken on both sides at once in multiplayer, a few tens of milliseconds; the last
`SLOWEST` line says how long the checks took in all. A kept `--stay` game prints what its last
run left behind as `DIRTY` lines when the next run starts, since that run starts on top of it.

## Choosing tests

`--failed` reads `dev/.runs-failed` in the mod's repository, which every `--test` run that got as
far as its tests rewrites for its kind (`test` or `test-mp`): the tests with a `FAIL` line, and
the test a Lua error or the timeout stopped. A run whose tests all passed leaves the list empty,
and `--failed` then runs nothing. The mod should gitignore it, as it does `dev/.runs.log`. At the
end of a run with failures the script prints `--failed reruns: <names>`.

`--changed` reads `git diff --name-only HEAD` and the untracked files, of the repository and of
the harness submodule, and the conf's `TEST_MAP` ([adopting.md](adopting.md#devharnessconf)).

## Where the time goes

The `<TAG> SLOWEST <s> s <name>` lines name the slowest tests, slowest first, and in multiplayer
how long each had a server answer outstanding (`(server <s> s)`). The last `SLOWEST` line splits
the run into the time in tests and the time between them: the runner waiting for the character's
square to load again after a test that went far, the leak checks, and in multiplayer the
server's resets and undos. In multiplayer it adds how much of both had a server answer
outstanding.

On exit, `run-client.sh` and `validate-server.sh` print a `timing: <phase> <s> s (<what>)` line
per phase, each from the end of the one before, then `timing: total`. The clock starts once the
script holds the game lock, so a wait for another script's game doesn't count. The phases are
`setup` (to the game's launch; in a kept game, to the rerun request), `boot` (to the harness's
Lua), `world` (to the world loaded around the character), `start` (to the first test), `run` (to
the last result), `quit` (to the game's exit, and with `--mp` to the server's after it saves), and
with a fresh `--mp` server `server` (its launch to ready, beside the client's boot). A run a Lua
error stopped has `stopped` (to the poll that saw the error) in place of `run` and no `quit`.
`validate-server.sh` has `setup`, `boot` and `quit` for its server. A phase the run never reached
is left out. The script reads the milestones off the console as it polls it, so they are good to
about half a second.

Each run also appends one line to `dev/.runs.log` in the mod's repository, which the mod should
gitignore: the date, `mode=` (`test`, `test-mp`, a mode's name, `validate`; `-rerun` for a run in
a kept game), `selection=` (`TESTS`, the mode's selection, or `all`), the counts of the `DONE`
line, `exit=` (the script's exit status), each phase as `<phase>=<s>`, and `total=`.

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
  while it waits, and quits after 30 minutes without a run or when another run needs the game.
- Early stop. In debug mode a Lua error stops the game in its error handler, so it never quits on
  its own. A Lua stack trace through any of the three mods, or any Lua failure once the harness
  has started, ends the run at once and prints the trace. An exception the game logs and goes on
  from (its frames indented twice), and anything on a server, which never stops at an error, fail
  the run in the scan after it instead.
- Silent. Harness runs set every volume in the cache's `options.ini` to 0; the sound engine still
  runs. Playing by hand keeps your volumes.

## Other behaviour

- One game at a time. Every script that starts a game, for any mod, takes the lock
  `$TMPDIR/PZ_DevHarness-game.lock` and waits while another holds it; a lock whose owner died
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
