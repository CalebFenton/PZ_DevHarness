# Running tests and modes

What `dev/run-debug-client.sh` does with each flag, why a run is fast, and the rules every run follows.

## Flags and environment

`dev/run-debug-client.sh`:

| Flags | What happens |
| --- | --- |
| none | Play by hand: the main menu, with the scenario under Scenarios and the tests under Debug menu > Dev > Unit Tests > Timed Actions. |
| `--test` | Runs every test of the mod and quits. Exits 1 on a failure or any Lua error. |
| `--test --stay` | The same, but the game stays open; the next `--test --stay` reruns the tests in it. |
| `--test --mp` | The same in multiplayer: a dedicated server and a client that joins it; see [multiplayer.md](multiplayer.md). |
| `--test --mp --stay` | Both stay open; the next `--test --mp --stay` reruns the tests in them. |
| `--<mode>` | Runs the mod's handler for the mode and quits. |

Environment: `TESTS=<prefix>,...` runs only the tests whose names start with one of them;
`TIMEOUT` caps a run in seconds (default 300 for `--test`, enough for a cold `--mp` run of a
whole suite, so it only catches a game that died; 1200 for the other modes); `CACHE` moves the cache dir (with `--mp` the
client's; `SERVER_CACHE` the server's); `SERVER_PORT` moves the `--mp` server off 16361 (it also
takes the next port); `JAVAC` names the compiler for `ClickToStart.java` (any JDK from 8 on; the
game's own Java has none); `PZ_APP` names another game `Contents` folder.

Console lines, in `<cache>/console.txt`: `<TAG> START <n>`, `TEST: <name>`, `<TAG> PASS <name>`,
`<TAG> FAIL <name>: <reasons>`, `<TAG> SKIP <name>: <why>` for each test that opted out of this
mode, each of those three ending with the test's wall time, `(<s> s)`; then `<TAG> SLOWEST` lines,
`<TAG> TIME <s> s, <n> frames`, `<TAG> DONE passed=<n> failed=<n> skipped=<n>`; with
`--stay` also `<TAG> RUN <id>` and `<TAG> IDLE ...`. With `--mp` the server's log
(`<server cache>/server-console.txt`) gets `<TAG> SERVER FAIL <test>: <error>` for a handler or
undo that failed, and `<TAG> RUN <id>` for a rerun. The script prints every line with the run's
mark and both logs' paths, and exits 0 only if the run finished, at least one test passed, nothing
failed and no Lua error was logged on either side.

## Where the time goes

The `<TAG> SLOWEST <s> s <name>` lines name the slowest tests, slowest first, and in multiplayer
how long each had a server answer outstanding (`(server <s> s)`). The last `SLOWEST` line splits
the run into the time in tests and the time between them: the runner waiting for the character's
square to load again after a test that went far, and in multiplayer for the server's resets and
undos. In multiplayer it adds how much of both had a server answer outstanding.

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
