# Adopting PZ_DevHarness

How a mod takes the harness on, what it tells the harness about itself, and the test library its tests use. The [README](../README.md) says what the harness is for; [running.md](running.md) covers the run script and [multiplayer.md](multiplayer.md) the `--mp` mode.

## Layout

| Path | What it is |
| --- | --- |
| `bin/run-client.sh` | The client runner behind a mod's `dev/run-debug-client.sh`, single player and multiplayer (`--mp`). |
| `bin/validate-server.sh` | Boots a throwaway dedicated server with the mod and fails on anything the mod logs. |
| `bin/static-check.sh` | The static check behind a mod's `dev/static-check.sh`: compiles the Lua with the game's compiler and cross-checks the mod against the installed game ([static-check.md](static-check.md)). |
| `bin/review.sh`, `lib/review.css` | The review pages behind a mod's `dev/review.sh`: lays out the README images and renders `REVIEW_DOCS` to HTML as GitHub shows them, the first also to a PDF, into `REVIEW_DIR` (`~/Nextcloud/ProjectZomboid` by default); `--art` adds the mod's `art/models/preview.py` page. Its header lists the files and what it needs. |
| `bin/package.sh` | The local test build behind a mod's `dev/package.sh`: one `REVIEW_DIR/mods.zip` holding every harness mod repository beside this one, each with its libraries and dev mod, and the harness mod, to unzip into `~/Zomboid/mods`. It prints the commit of each folder and stops while one has uncommitted changes; `--dirty` zips them anyway. A folder two repositories ship, such as a library or the harness mod, must be the same in both. |
| `check/` | The static check's Java probe and Python checker, and the `.pack`, `.tiles` and `.lotheader` readers it and a mod's plugins use. |
| `lib/harness.sh` | Paths, JVM arguments, the game lock and a kept `--stay` game's reruns, `install_mod`, `compile_java`, the client cache (`prepare_cache`) and the dedicated server the scripts start (`prepare_server`, `prepare_mp_server`, `start_server`, `server_started`, `stop_server`, `server_problems`). A mod's own dev scripts may source it. |
| `lib/tests.py`, `lib/results.py` | Which tests a run runs and what a failure points at: `TEST_MAP`, `--changed`'s batch, `--failed`'s record and the suspects ([running.md](running.md#choosing-tests)); and the one reader of a `--test` run's result lines, for those and the verdict. |
| `lib/capture.py` | Crops a [capture mode](#capture-modes)'s screenshots into the mod's captures. |
| `lib/promo.py`, `lib/fonts/` | Lays out a mod's README images, Workshop gallery, poster, preview and mod icon from those captures, imported by the mod's `art/promo/compose.py` ([workshop-page.md](workshop-page.md#laying-out-the-images)), with the NotoSans font it draws in. |
| `lib/trace.py` | Reports where a `TRACE=1` run's time went and writes it as a Perfetto timeline ([running.md](running.md#where-the-time-goes)). |
| `lib/census.py` | Counts the rooms, container tiles by room and vehicle stalls of the vanilla towns and the whole map into a Lua table at `--out`, for a mod's loot report; its docstring has the formats it reads. |
| `lib/findloot.py` | Lists the loot lists and rooms that roll an item and where on the vanilla map those rooms stand, or every building with a room type, from the installed game's files ([find-loot.md](find-loot.md)). |
| `lib/art/`, `lib/blender.sh` | The art library a tile and item mod's `art/models` and `tools` build with: mesh and material helpers for its Blender builders, the tile, depth map and icon renderer, review sheet helpers, deterministic FBX export, the `.tiles` and texture pack writers, and the Blender invocation its `make.sh` sources ([art.md](art.md)). |
| `java/ClickToStart.java` | Starts the client, presses "Click to start" on the loading screen, gives the asset loader more threads (`java/AssetLoading.java`), loads the tile depth maps early (`java/DepthMaps.java`) and in multiplayer sends every packet at once (`java/NetLatency.java`). |
| `java/FastServer.java` | Starts the dedicated server of `--mp` and `validate-server.sh` with the same wider asset loader, sending every packet at once. |
| `mod/42/` | The harness mod (`cf_test_harness`): `client/PZHarness/Runner.lua`, which registers the mod and starts its modes, `Run.lua`, the files the run script and the game talk through and `PZHarness.run`, `Schedule.lua`, which runs the tests one after another and sums up the run, `Report.lua`, the verdict lines and the failures that come after them, `Stay.lua`, the reruns of a game kept by `--stay`, `Multiplayer.lua`, the `--mp` client's join, `TestLib.lua`, `ServerCalls.lua` and `Leaks.lua`, the leak check between tests, `Trace.lua`, what a `TRACE=1` run records, `Capture.lua`, the steps and shots of [capture modes](#capture-modes), `Stage.lua` and `StageLots.lua`, their [staging](#staging), and `QA.lua`, the setup of [QA scenarios](#qa-scenarios); `server/PZHarness/ServerHandlers.lua`, the server's half of the tests' server channel, `ServerFixtures.lua`, the server's half of the two-sided fixtures, `ServerChecks.lua`, of server checks and [reads](#the-test-library) of what the character carries, and `ServerLearning.lua`, of [recipe learning](#the-test-library); `shared/PZHarness/Fixtures.lua`, what both halves do, `Checks.lua`, expectations for server handlers, `Loot.lua`, the loot tables and rolls of [loot checks and reports](#loot), and `Snapshot.lua`, what the leak check reads on each side. |

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
| `MODES` | The mod's other modes, space-separated; each becomes a `--<mode>` flag. Describe them in a comment above it. A mode's console mark, which the run waits for as `<mark> DONE` and the handler reads as `PZHarness.run.mark`, is `TAG` without its `Test` and the mode capitalised (`MyModShots` for `MyModTest`'s `--shots`); its selection comes from the environment variable named after it in capitals (`SHOTS`), as `TESTS` is for `--test`. |
| `MODE_GROUPS_<mode>` | Optional: the groups a [capture mode](#capture-modes) shoots, space-separated, in the order a run takes them. The selection may name only these, or the run fails before the game starts and lists them; the handler gets the named ones, or every group if the selection names none, comma-separated in this order, and all of them as `PZHarness.run.groups`, so a group of the handler's own that the conf lacks fails the run (`Stage.runGroups`) rather than go unshot. |
| `MODE_CAPTURES_<mode>` | Optional: the folder, such as `art/promo/captures`, that a [capture mode](#capture-modes)'s shots are cropped into after a run that finished cleanly. |
| `TEST_MAP` | Optional: a bash array of `'<glob>=<prefix>,<prefix>'` entries for `--test --changed` and for the `suspects` lines after a failure ([running.md](running.md#choosing-tests)). Each glob is matched against paths relative to the repository, `*` crossing `/`; every entry a file matches adds its test name prefixes (`=<name>` for one test exactly), and an empty list (`'<glob>='`) adds none. A dev mod Lua file whose name has `Tests` registers tests and selects them itself (`@<file>`; `T.test` records each test's file), and a harness mod file reaches every test, so neither needs an entry; a line for a harness file narrows it, as for a feature module only some tests load. Every other file under the mod and the dev mod needs an entry, and every glob must match a file of those or the harness mod: `dev/static-check.sh` and `--changed` fail otherwise, naming each file without a line and each glob that matches none, so a new or renamed file shows up in the map at once. A file every test depends on names the mod's test prefix, the `prefix` it registers, which selects every test; files elsewhere, such as docs and art, reach no test and take no entry. The runner fails an entry that names no test. `lib/tests.py` owns the map. |
| `CHECK_PLUGINS` | Optional: a bash array of Python files with the mod's own static check rules ([static-check.md](static-check.md#plugins)). |
| `CHECK_ALL_LANGUAGES` | Optional: set to make the static check fail on any language the game offers that lacks a translation file or key English has. |
| `QUIET_WORLD` | Optional: a bash array of `Key=value` sandbox options that make a `--test` world quiet, replacing the harness's list ([running.md](running.md#a-quiet-world)); `QUIET_WORLD=()` keeps the world's own population. |
| `TEST_SANDBOX` | Optional: a bash array of the mod's own sandbox options for a `--test` world, as `Table.Key=value` (a number, `true` or `false`), such as `(MyMod.RandomSpawns=1)`. They are set with `QUIET_WORLD`'s, in single player before the scenario's `setSandbox` and on the `--mp` server where `harness_server_setup` set nothing ([running.md](running.md#a-quiet-world)). |
| `SERVER_PROBLEMS` | Optional: an extended regex of server log lines that count as the mod's problems, besides stack traces through it. |
| `SERVER_IGNORE` | Optional: an extended regex of matching lines that don't count. |
| `TELEMETRY_FILE` | Optional: the switch file, in `<cachedir>/Lua`, that the mod's libraries read their telemetry channels from, such as `cf_telemetry.txt`. `TELEMETRY` writes it for a run ([running.md](running.md#flags-and-environment)). |
| `WORKSHOP_REPO` | Optional: the GitHub repository, as `owner/name`, whose `README.md` [`dev/workshop-txt.sh`](workshop-page.md) turns into `workshop.txt`'s description; its relative images and links point there. With it set, the static check fails while `workshop.txt` is out of date or over Steam's limit. |
| `WORKSHOP_BRANCH` | Optional: the branch those images and links point to; `master` by default. |
| `WORKSHOP_SKIP` | Optional: a bash array of the README's `##` headings to leave off the Workshop page, such as `(Install Development)`. |
| `WORKSHOP_GALLERY` | Optional: the folder of gallery images [`dev/workshop-gallery.sh --upload`](workshop-page.md#the-gallery) puts on the Workshop item; `art/promo/gallery` by default. |
| `REVIEW_DOCS` | Optional: a bash array of the Markdown files `dev/review.sh` renders, such as `(README.md docs/player-guide.md)`; the first is also printed to a PDF. `(README.md)` by default. |

A hook, a bash function the conf may define:

| Hook | When it runs |
| --- | --- |
| `harness_server_setup` | After a server's `$CACHE/Server/$SERVER_NAME.ini` is written: in `validate-server.sh`, and for the server of `--mp`, whose sandbox then gets `Zombies = 6` and the `QUIET_WORLD` and `TEST_SANDBOX` options it doesn't set appended; add files such as `${SERVER_NAME}_SandboxVars.lua`. `$MP` is `1` for the `--mp` server. |

The hook can read `$REPO`, `$CACHE`, `$MOD_DIR`, `$DEV_MOD_DIR` (absolute by then), `$MODE` and `$MP`;
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

```sh
#!/usr/bin/env bash
# dev/review.sh
. "$(dirname "$0")/harness/bin/review.sh"
```

```sh
#!/usr/bin/env bash
# dev/package.sh
. "$(dirname "$0")/harness/bin/package.sh"
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
        -- calls done() when finished; done prints "<mark> DONE" and quits. `capture` is optional;
        -- see [capture settings](#capture-settings).
        shots = { capture = true, run = function(selection, done) Shots.capture(selection, done) end },
    },
    onStart = function(mode) end, -- optional, after the scenario's own onStart in every mode
})
```

The test library's settings and hooks go in a file of the dev mod's shared Lua, since a
multiplayer server loads no client Lua and both sides read the same registration: in single player
a fixture placed through the server channel (`placeTile`, `placeBench`, `placeVehicle`) and one
placed directly (`track`) are removed by the same `remove`.

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
| `remove(object, player)` | both | Removes a placed object of the mod the way the mod does and returns true; anything it returns false for goes the vanilla way, a running generator switched off first. Every fixture removed when a test ends goes through it, whichever side placed it; `player` is the character whose test placed it, when the remover knows it. |
| `spawnVehicle(script, square, facing, args, defer)` | server | Makes the vehicles `placeVehicle` asks for, with the test's `opts.args`, returning one, or nil to leave it to `addVehicleDebug`; `defer` takes undos, as a handler's does. |
| `chance()` | server | The mod's roll module, whose `roll()` every chance of the mod draws through (cf_commonlib's `Chance`), for `forceRoll` and `PZHarness.Rolls`. |
| `records` | both | The kinds of Global Object System record the record kit drives, by name: `{ owner(), build(square, tile)?, containers(object)?, extras(record, object, state)? }` (`server/PZHarness/ServerRecords.lua`). |
| `jobAction()` | server | The mod's job action class (cf_commonlib's `JobAction.forFeatures`), for the job kit's `job`. |
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

function T.gadget(self, square) return T.placeTile(self, square, "mymod_01_0") end
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
- `newItem(fullType, fluid)` (its fluid container full of `fluid`; nil for a
  type the game lacks), and `buildAsPlayer(player, sprite, nSprite, x, y, z)`, which builds the
  build menu entity of the tile `sprite` there as the build menu does (`ISBuildIsoEntity:create`),
  turned by the cursor's rotation `nSprite`, the build cheat standing in for materials and the job;
  it returns what is missing, or nil.
- `printSummary(mark, line, summary, lists)` prints `line` under `mark`, then one line for each
  field of `summary` named in `lists` that is a non-empty list or a string: what the setup laid
  out, then what it couldn't.
- `newSummary()`: a summary for the two below to count into (`types`, `items`, `groups`, `tools`,
  `boxes`, and the lists `toolboxes`, `unknown`, `unplaced`), which a setup adds its own fields to.
- `packToolboxes(player, stock, summary)`: puts the kept vanilla tools of `stock` (`{ type, used,
  kept }`, as `materials` gives) in `Base.Toolbox`es in `player`'s inventory, the first two in the
  hands. A tool goes in if vanilla files it as `Tool` or `ToolWeapon` and it weighs less than a
  toolbox's MaxItemSize; room is the toolbox's own capacity, not any character's. Kept items that
  don't go in are added to their entry's `used`.
- `layGroups(origin, width, groups, summary, opts)`: lays `groups` (`{ name, items }`, each item
  `{ type, count, fluid }`) from the square `origin` in rows `width` wide running south, a square
  to each item, each group from a new row past an empty one. `opts.maxRows` bounds it;
  `opts.accepts(square)` says where an item may lie (any loaded square without it), and the layout
  skips the rest; `opts.after[name](layout, summary)` places what a group sets after its items with
  `layout:nextSquare()`, `nextRun(length)` (squares in a row east) and `nextOpenRow()` (a whole
  row); `opts.newItem(entry)` makes an item (`newItem(type, fluid)` without it). Types the game
  lacks go in `unknown`, items left without a square in `unplaced`.

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

`PZHarness.Test` is the test library a mod's own inherits. Its modules add to the same table; a
mod's test library requires each one its tests use, never the internal `TestRuntime.lua`. Each
module's header says what it is for and the rules it keeps, and each function's `---` comment
what it does, so read those rather than a list here:

| Module | What it has |
| --- | --- |
| `PZHarness/TestLib.lua` | Registering (`test`; its spec's `hour`, `instant`, `sandbox`, `spOnly` or `mpOnly`, `timeoutSeconds`), expectations and `need`, the restore stack (`defer`, `onTick`), the two-sided setters (`setTime`, `setPerk`, `setSandbox`, `setMultiplier`, `setGrid`, `setMechanicsCheat`, `makeDark`, `changeItem`; see [two-sided fixtures](multiplayer.md#two-sided-fixtures)), the server's copy of the character (`setStat`, `takeItems`) and its rolls (`forceRoll`, `UNDER`). Its header has the rules that keep each test independent of the ones before it. |
| `PZHarness/TestRuntime.lua` | Loaded by `TestLib.lua`: the queue (`wait`, `waitUntil`, `waitFor`, `waitForLight`, `step`, `describeAction`) and the server channel (`server`, `serverUntil`, `give`, `count`, `batch`; [multiplayer.md](multiplayer.md#the-server-channel)). |
| `PZHarness/TestWorld.lua` | Squares and handles (`squares`, `square`, `where`, `at`, `copyOf`), fixtures placed by the server or by the character as a player does, this game's own (`track`), what the test leaves on a square (`trackSquare`), floor items and floors (`floorItem`, `takeFloorItems`, `floorAbove`, `ringOfTiles`), vehicles, and walking and jobs (`standNextTo`, `goNextTo`, `doJob`). The server handlers `PZHarness.objectModData` and `PZHarness.worldFrame` (`ServerFixtures.lua`) take `read` and `serverUntil` directly. |
| `PZHarness/TestLearning.lua`, `server/PZHarness/ServerLearning.lua` | Recipe names, knowing and forgetting recipes on both sides, recipe skills, level ups as the game awards them, and the AutoLearn tests (`autoLearnTests`). |
| `PZHarness/TestCraft.lua` | Recipe inputs (`inputItem`, `inputCount`, `recipeInputs`), work tables, crafting through the game's menus (`startCraft`, `craft`) and `craftTest`; requires `TestWorld` and `TestLearning`. |
| `PZHarness/TestBuild.lua` | Building from the build menu (`buildEntry`, `placeable`, `buildSite`, `build`, which tracks its square); requires `TestCraft`. |
| `PZHarness/TestMenus.lua` | Context menus: building, finding, reading, noting and choosing options; tooltip text laid out (`runTogether`); requires `TestWorld`. |
| `PZHarness/TestReads.lua`, `server/PZHarness/ServerChecks.lua` | Reads kept on the test (`read`, `readUntil`, `findIn`), server checks (`expectNoFailures`, `serverCheck`), the server's copy of the character (`readCharacter`, `xpAward`), and what the character carries on either side. |
| `PZHarness/TestRecords.lua`, `server/PZHarness/ServerRecords.lua` | The record kit, for the kinds of the `records` setting: `placeRecord`, `setRecord`, `fillRecord`, `ageRecord`, `readRecord`, `reloadRecord`, `onRecord`, `recordSummary`, `waitForSummary`; `PZHarness.Records` for a dev mod's handlers (`at`, `set`, `read`, `track`). |
| `PZHarness/TestJobs.lua`, `server/PZHarness/ServerJobs.lua` | The job kit, for the `jobAction` setting's class: `job` (with reads before and after in the same call), `expectOk`, `expectRefused`. |
| `PZHarness/TestChunks.lua` | Trips away: chunk reload trips (`reloadChunk`) and visits to far places (`startVisits`, `visitUntil`, `returnHome`). |
| `shared/PZHarness/Fixtures.lua` | What both sides do, for a dev mod's server handlers too: lookups (`squareAt`, `overlaysOf`, `fieldsOf`, `ring`, `buildingNear`, `worldItems`, `newSince`, `teleportToMiddle`), building and removing (`newTile`, `newBench`, `removePlaced`, `releaseGeneratorPower`), and undoing (`deferOnce`, `replace`, `saveOptions`). `server/PZHarness/ServerFixtures.lua` adds the handlers' `PZHarness.squareAt`, `vehicleAt`, `squareFor` and `trackSquare`, `ServerHandlers.lua` `PZHarness.readsAround`. |
| `shared/PZHarness/Rolls.lua` | Setting the `chance` setting's rolls in a server handler: `PZHarness.Rolls.force`, `with`, `eachTrial`, `trialRoll`, `UNDER`. |

The runner (`PZHarness/Schedule.lua`) fails a test still busy after 30 seconds of real time with
what it was waiting on (`describeAction`), clears its queue, runs its undos and starts the next;
`spec.timeoutSeconds` raises the limit for a test that is slow on purpose. A test whose starting
square still hasn't loaded some seconds after the test before took the character far away fails
without running.

## Loot

`PZHarness.Loot`, from `PZHarness/Loot.lua`, for a dev mod's loot checks (server handlers, since
only the authority's loot tables are filled) and its loot report mode, which rolls on the client.
It is shared Lua, so both roll the same way. What the mod puts in which lists, and the labels a
report prints, stay in the dev mod.

- The tables: `forEachItemsList(fn)` calls `fn(items, path)` for every `items` list of every room, container, bag, procedural and vehicle table. `procListUsers()` is, for each `ProceduralDistributions` list, the first procedural room container that picks it (`{ room, container }`): `ItemPickerJava.getItemContainer` finds a list only through one. `proceduralList(name, users)` is the game's parsed copy of a list, and that user, or nil. `rarityOf(fullType)` is the loot rarity option that scales an item (its name and the option), or nil and the item's loot type.
- Options: `withMeasureOptions(options, fn)` runs `fn` with the game's sandbox options `options` (name -> value, or `DEFAULT` for the option's default) and the General debug log off, which in debug mode logs every roll into a container off the map. It reloads the loot multipliers, which the game caches, on both sides of `fn` (`ItemPickerJava.InitSandboxLootSettings`), and puts everything back even when `fn` throws, as `restoring(fn, restore)` does for a mod's own changes. A mod's own loot options in a server check go through `PZHarness.Fixtures.saveOptions`.
- Rolling: `withParsed(containers, lists, fn)` has the game parse container tables of the dev mod's making (under a made-up room, with `lists` for the procedural ones to pick), passes `fn` the parsed copies by key, then takes them out and parses again. `rollFill(list)` is a fill that rolls a parsed table as a container fill does. `fillOnce(fill, container, read)` empties a scratch container, fills it and returns `read(container)`: by default `countItems(container)`, fullType -> count with bags' contents, and `countItems(container, matches)` counts only the types `matches(fullType)` takes. `sample(fill, samples, container, read)` fills `samples` times and gives, for each key `read` counts, the `share` of samples with one and the mean count in those, `perContainer`. Each fill's items come off the cell's processed items (`forgetItems(container)`), where `ItemContainer.AddItem` puts every new item and thousands of fills in one frame would pile up until the game runs out of memory.
- `scratchContainer(square)` is a crate that never enters the world, to fill and read; `squareOutsideRooms(character)` is the nearest ground-floor square in no room, the square to give a container that rolls procedural tables: only one on a square does, and one in a room counts toward the room's list limits.
- Reporting: `share(fraction, percentPlaces, oneInPlaces)` formats a share of samples as `<percent>% (1 in <n>)` with those decimals, or `none` at 0. A report prints its lines under `PZHarness.run.mark`, which `run-client.sh` reads them by.

## Capture settings

A registered mode with `capture = true`, for one whose steps wait on the lighting, the zoom and the
UI rather than on frame counts, gets these from just before `run` until `done()`, which puts the
UI rate back before the game quits and saves its options, so `options.ini` never keeps it:

- As many frames as the machine can draw, as `--test` does; [running.md](running.md#why-it-is-fast-and-what-that-costs) explains why that's safe.
- A clear sky: no cloud, fog or rain, at once and however the weather turns during the run. It stops the weather and sets the admin values of the climate's cloud, fog and precipitation floats to 0; stopping the weather alone leaves fog to fade out over seconds.
- The UI drawn 120 times a second, the `uiRenderFPS` option's highest. The UI draws at its own rate and the frames in between show its last drawing, so a step that waits for the UI to draw (`Events.OnPostUIDraw`) waits less.

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
    local run = Capture.new()                  -- logs under the run's mark
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
  see [capture settings](#capture-settings)), `Capture.zoomSettled()`, and `Capture.DRAW_FRAMES`, enough drawings or frames for
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
  item with a tag shows (as `PZHarness.Test.inputItem` picks) and `opts.fluidContainers` the
  container, by fluid type, a line that takes or fills any container shows. `learn.magazines`
  names the items whose script teaches the recipe (`LearnedRecipes`), sorted by name, as
  `learn.research` names those that research it.

`lib/capture.py <cache dir> <mark> <captures folder>` turns a matted pair into alpha (a pixel
that reads k on black and w on white has alpha 1 - (w - k) and colour k / a), crops every region
and writes the rest of `<mark>.json` to the folder's `promo.json`, with the captures each group
made. Only the groups the run shot are replaced, and a group's captures it no longer makes go.

Item models for `ItemSheet(models=True)` ([workshop-page.md](workshop-page.md#laying-out-the-images))
come from data with a `models` list: each entry `{ name = "model_<Module>_<Type>", group, file,
floor, window }` names the item's screenshot, a screenshot of the same floor with nothing on it,
and the region, in UI units, the item lies in. Where the shot differs from the floor is the item:
capture.py crops it with a margin, its longer side within `MODEL_MAX` pixels, and gives its box in
that crop as `promo.json`'s `models`. A run that shot no models keeps the last boxes. Then
capture.py prints `extract: no capture <name>.png` for each icon the catalog's items and recipes
name, and with `models` each item's model, that no run has made.

### Staging

`PZHarness.Stage`, from `PZHarness/Stage.lua`, holds what staging a world shot takes, and
`PZHarness/StageLots.lua` adds open ground, lots and places to it; its waits are runSteps waits
and its `add...` functions add steps to a run:

```lua
local Stage = require "PZHarness/Stage"
require "PZHarness/StageLots"

local lots
local groups = {
    yard = {
        places = { "yard" },
        add = function(data)
            -- Looks around from the square (squares never seen draw dark), a step out from the closest zoom.
            Stage.addGoTo(run, getPlayer(), { Stage.at(lots.yard, { 2, 5 }) }, 1)
            run:addOpaque("yard", function()
                return { Stage.centred("yard", Stage.lotSquares(lots.yard)) }  -- README-wide, the lot in the middle
            end)
        end,
    },
}
local places = {
    { name = "yard", label = "yard", missing = "open ground 4x4", find = function(player, found)
        return Stage.findLot(player, 4, 4, { trees = true, others = found, gap = 6 })
    end },
}
Stage.runGroups(run, selection, {
    groups = groups,
    places = places,                                             -- none found fails the run with what's missing
    catalog = Capture.newCatalog(),                              -- item and recipe names, and an `icons` group
    items = { "MyMod.Widget" },
    data = { strings = { modName = getText("Sandbox_MyMod") } },
    prepare = function(chosen, found, origins)
        lots = found
        Stage.addWorldSettings(run, { hour = 12, origins = origins })
        run:add(function()
            Stage.clearLotForShots(lots.yard, 2)                 -- its trees and ground cover go
            Stage.placeTile(Stage.lotSquare(lots.yard, 1, 1), "my_mod_tiles_0")
        end)
    end,
}, done)
```

- Finding and clearing: `closestSquare(player, accepts)` (within `SEARCH_RADIUS`, nearest first,
  then west, then north), `eachSquareAround(x, y, z, radius, fn)`, `removeTrees(x, y, z)` (within
  `TREE_RADIUS`: near a building a tree out of sight draws as a black silhouette),
  `isGroundCover(object)` and `clearGroundCover(square)` (grass, weeds, bushes and litter),
  `removeVehicles(x1, y1, x2, y2, z)`, and `silenceRadios(origins)`, as radio and television
  captions float over the shots.
- Open ground and lots (`PZHarness/StageLots.lua`): `isOpenGround(square, opts)` holds for a
  loaded square outdoors and in no room, on solid floor that isn't water, with no vehicle and
  nothing on it but its floor and ground cover (a boulder, which carries the floor flag too, is
  not floor), nor a wall unless `allows` takes it. `opts`: `bare` (nothing but its floor), `trees`
  (trees too), `allows(object)` (other objects too), `floor` (a prefix
  the floor's sprite name starts with: `NATURAL_FLOOR` for soil or grass) and `free` (nothing on it
  stops a character walking on, `IsoGridSquare.isFree`). `isAreaOpen(corner, w, h, accepts)` holds
  when `accepts` does for every square of the rectangle (nil for one not loaded).
  `findLot(player, w, h, opts)` is the closest lot `{ x, y, z, w, h }` (its north-west corner) of
  open ground with `opts`, or nil; `opts.others` lists lots it keeps `opts.gap` squares from, and
  `opts.clearance` squares round it must be open ground of any floor too, so no building or fence
  stands at its edge. A lot is also a place on its corner. `lotSquare(lot, dx, dy, up)` is a square
  of it (nil if not loaded), `lotSquares(lot)` all of them, as a framing takes them, and
  `recalcLot(lot)` recalculates it and the squares beside it, so that what was set on it draws.
- Places (`PZHarness/StageLots.lua`): a place is an `origin` square and a `frame`, the directions a
  position `{ along, out }` runs in (`GRID`: east, south); `place(origin, frame)` makes one, and
  `at(place, position)`, `squaresAt(place, positions...)`, `loadedSquares(place, positions,
  accepts)` and `everyAreaSquare(place, area, fn, outFrom)` (an area is `{ along = { from, to },
  out = { from, to } }`, with `sum` and `half` a diagonal band of it) read its squares.
  `closestPlace(player, frames, fits, others, gap)` is the closest place in the first of `frames`
  that has one `fits(place)` takes, its origin `gap` along x or y from each of `others`'.
  `findPlaces(player, specs, needs, mark, gap)` finds, in order, each spec `needs` names, apart
  from those found before it, logs them on one line, and returns them by name and their origins,
  or nil and the first one's `missing`; a spec is `{ name, label, missing, frames, fits(place,
  player) }` or `{ name, label, missing, find(player, found) }`, `detail(place)` adding to its log
  entry. `runGroups` calls it for a mode's `places`.
- Spot and model shots: `addSpotShot(run, player, lot, { name, x, y, zoomSteps, hour })` walks
  the character to a square of the lot and shoots the screen with no regions, for a mode that
  writes no JSON. `STUDIO_PLACE` is the spec of a patch of open ground for item models, and
  `addFloorModels(run, studio, items, models, floorSprite)` lays `floorSprite` there, drops every
  item at once so their models load, and shoots the bare floor (`models_floor`) and each item
  alone on it, turned `STUDIO.rotation`, at the closest zoom, adding each to `models` (the data's
  `models` list, see above).
- Dressing: `dress(player, look)` with `hair` sets `female`, that hair, no beard and `hairColour`
  if given, and with `clothes` (full types, made once per look) or `ownClothes` (what the character
  wore before a look first changed it) wears only those and holds `weapon` (made once) or nothing.
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
- `runGroups(run, selection, mode, done)` runs a capture mode's groups. `mode.groups` maps each
  name to `{ add(data), places }`; it fails a selection that names a group it lacks, and any run
  whose groups (the catalog's `icons` among them) include one the conf's `MODE_GROUPS_<mode>`
  leaves out, which a full run would never shoot. With
  `mode.places` it finds, `mode.gap` apart, only the places the chosen groups name (findPlaces) and
  fails the run with `within SEARCH_RADIUS squares, no <missing>` if one isn't there. With
  `mode.catalog`, the data holds the catalog's `items` of `mode.items` and its `recipes`, and the
  group `icons` shoots their icons. Then `mode.prepare(chosen, places, origins)` adds the steps
  that set and build the world and returns why the run can't go on, if it can't. It hides the UI,
  puts the mouse in a corner, where the world outlines nothing and no menu follows it, adds each
  group's steps under `run:group`, logs `<mark> TIME <group> <seconds> s` for each and the total,
  and runs the run with `mode.data`.
