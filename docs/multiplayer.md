# Multiplayer

How `--test --mp` runs a mod's tests against a dedicated server, and what a test written once needs to run in both modes.

`--test --mp` takes the lock once, then:

1. Prepares two cache dirs, `$TMPDIR/<CACHE_NAME>-mpserver` and `-mpclient`, each with a copy of
   the mod and links to the harness mod and the dev mod.
2. Writes the server's `harness.ini` (the three mods, ports 16361 and 16362, `Open`, `PauseEmpty`
   off) and runs the conf's `harness_server_setup`, then appends `Zombies = 6` to its sandbox, so
   the world has no zombies, as the scenarios' do, and the `QUIET_WORLD` options the hook didn't
   set ([a quiet world](running.md#a-quiet-world)). Every cold run starts a new world.
3. Starts the server with FastServer, through `start_server` in `lib/harness.sh` as
   `validate-server.sh` does, and the client with ClickToStart at the same time. The client waits
   at the main menu until the script writes `<client cache>/Lua/PZHarnessConnect.txt`, once the
   server's log says it started, then joins as the server's admin: a `-debug` client must have the
   ConnectWithDebug capability. Overlapping the boots saves seconds on every run; joining before
   the server listens would only fail.
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

## The server channel

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

## Two-sided fixtures

The library's fixtures act on both copies, so a test written once runs in both modes and single
player behaves as before:

- Setters (`setSandbox`, `setTime`, `setMultiplier`, `setGrid`, `setPerk`, `changeItem`, the
  test's `instant` and `perks`) change this game's copy at once; on a multiplayer client they also
  send the change to the server (handlers named `PZHarness.*` in `ServerFixtures.lua`) at once and
  queue a wait for its answer, so actions queued after them start once the server has it. The
  server undoes it when the test ends. A dev mod's server Lua sets
  `PZHarness.serverSettings.sandboxChanged` for what the client's `tests.sandboxChanged` does.
  A client lights its squares with the daylight the server sends it, which the server does only
  every ten game minutes, so the server's `setTime` (and its undo) makes its next climate tick
  send it; `makeDark` then waits, up to 10 seconds, for this client's light to follow.
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
  The server gives a new vehicle the id it freed last, often the previous test's vehicle's, so
  `placeVehicle` never takes a copy it found for an earlier handle, which a client still holds
  until it takes the removal.
  On a multiplayer client it also waits 300 ms after its copy arrives: a client meeting a new
  vehicle id can ask for two full updates, the server sends the second in place of pending part
  changes, and a client that has the vehicle takes only its position from it, so a part change
  made in between would never reach the copy.
  `placeAsPlayer` gives the item (`give`), and the character places it with the moveables action,
  whose `complete()` the server carries out; `PZHarness.trackPlaced` then removes it on the server
  when the test ends, as above.
  `T.placeWorkTable`, `T.learnRecipes` and `T.forgetRecipes` work outside tests too, as in a
  scenario's onStart; `PZHarness.ServerCalls.callOutsideTest(name, args, onReply)` calls any
  handler there.
- The runner resets the server's copy of the character before every test too, and after the
  scenario's and the mod's onStart copies the client's perk levels and known recipes to it. The
  first test starts once the server has them and this client shows the levels again: the server
  replaces the client's perk list with its own copy's every second (`PlayerXpPacket`), and one it
  sent before it had the levels can land after its answer, leaving the skills too low for the first
  crafts. Waiting more than 5 seconds for that prints a `FAIL` of its own. For the same reason
  `setPerk` on a multiplayer client puts its level back on this client whenever such a sync
  changes it, until the test ends; a stale sync otherwise made a mid-run craft "skills too low".
- After each reset the runner refreshes the inventory windows at once, in both modes. Crafts and
  the craft menu take their inputs from the containers those windows list, which otherwise catch up
  only when the UI next draws; a multiplayer character starts with a key ring, and its removed
  container, still listed, can't be named to the server ("Unable to resolve container location"),
  so the first test's craft never started.

## What a client can and can't do

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

## Known noise and limits

- Joining resets the client's Lua (`Core.ResetLua`), so every mod's Lua loads twice on the
  client: once at boot, as in single player, and once as a multiplayer client. Load-time side
  effects outside Lua (files, Java state) happen twice. The reset also logs a
  `NoSuchFileException` for each mod without `media/AnimSets`; vanilla's, harmless, and not
  counted.
- The client doesn't pause when it loses focus, but like any run it takes keyboard focus while its
  window is up.
- Only `--test` runs in multiplayer; the mod's other modes are single player.
