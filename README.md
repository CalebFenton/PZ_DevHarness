# PZ_DevHarness

Automated tests for Project Zomboid Build 42 mods, played in the real game. Each test is a few lines of Lua: what a player does (pick something up, choose a menu option, craft, pull a part off a car) and what should be true afterwards. One command starts the game, plays every test with nobody at the keyboard, in single player or against a real dedicated server, then quits and tells you what broke and why.

It's fast enough that you'll run the tests after every change instead of promising yourself you'll run them before release. Renewable Energy, the mod it was built for, runs its whole suite in about a minute in single player and a little over two in multiplayer, game startup included.

## What a run looks like

A test queues what the player does in `run`, and checks the result in `validate`:

```lua
T.test("mymod_kettle_makes_tea", {
    hour = 10,
    run = function(self)
        T.give(self, "kettle", { { type = "MyMod.Kettle" } })
        T.step(function()
            local kettle = T.player():getInventory():getFirstType("MyMod.Kettle")
            ISTimedActionQueue.add(MyMod.BoilAction:new(T.player(), kettle))
        end)
        T.count(self, "after", { "MyMod.Tea" })
    end,
    validate = function(self)
        T.expect(self.counts.after["MyMod.Tea"] == 1, "boiling the kettle made no tea")
    end,
})
```

The character performs the same timed action a player would, animation and all, so the test exercises the mod's real code. Here is a trimmed run of a real Renewable Energy test that caught a multiplayer bug: after a player pulled the bulb out of a garden light, the lamp kept shining on their screen until the next game minute.

```text
$ TESTS==renewable_energy_gadgets_garden_light_remove_bulb dev/run-debug-client.sh --test --mp
RETest START 1
RETest FAIL renewable_energy_gadgets_garden_light_remove_bulb: this client's lamp went out only at a later game minute (7.75 s)
RETest DONE passed=0 failed=1 skipped=0
FAIL: not every test passed
--failed reruns: renewable_energy_gadgets_garden_light_remove_bulb
```

The script exits 0 only when every test passed and no Lua error was logged, so it can gate a commit or a release.

## What it does for you

### It plays the game for you

Zomboid already ships a test runner, in its debug menu: you launch the game, load a world, click through **Debug** > **Dev** > **Unit Tests** > **Timed Actions** > **Run All Tests**, and watch your character perform each test. The harness runs the same kind of test with no hands. It starts the game in debug mode without Steam, in a throwaway folder of its own, so your saves, settings and mod list are never touched. It loads three mods: your published mod, a dev mod that holds your tests, and the harness itself. The dev mod is never uploaded, so the mod your players download holds only game code.

Runs are silent, since the harness turns every volume down in its own folder. Only one game runs at a time across every mod that uses the harness; a second run waits its turn instead of fighting the first over ports and your keyboard.

### It reaches into the game with Java

Project Zomboid is a Java program. Lua mods, the harness's own Lua included, only get the parts of it the developers handed to Lua, and some of what a hands-free run needs isn't among them. Lua can't press "Click to start" on the loading screen, for one, so an unattended game would wait there forever.

So the harness doesn't start the game the usual way. It starts a small Java launcher of its own, [`ClickToStart.java`](java/ClickToStart.java), which starts the real game inside the same program. Sharing the program lets the launcher look at the game's internals while it runs, through Java's reflection: code can look up another class's private fields by name and change them. The launcher waits for the loading screen and sets the flag a real click would set. It also gives the game more worker threads for loading textures, models and animations; the game uses at most 4, and on an M3 Max the loading screen went from about 8 seconds to about 2. And it loads the tiles' depth maps, which the game loads one at a time after everything else, while the main menu shows, so the world is ready about a second sooner. The dedicated server for multiplayer runs starts through a twin, [`FastServer.java`](java/FastServer.java), which gives the server the same loader threads and took its start from about 18.5 seconds to about 14. In multiplayer both have the game send every packet at once, instead of on its network library's next pass about every 10 ms, which took Renewable Energy's multiplayer suite from about 189 seconds to 163.

The game's files stay as Steam installed them: the launchers change the running game in memory only, and they live only in the harness, never in your published mod. If a game update renames something they reach for, they print so and leave the game alone: it loads slower, or waits for you to click.

### It's quick

| | Vanilla debug menu | PZ_DevHarness |
| --- | --- | --- |
| Starting a run | Launch through Steam, load a world, click through the menus. | One command. |
| Between tests | A one-second pause so you can read the result. | The next tick. |
| Frame rate | Your frame cap, 60 frames a second by default. | Uncapped, about 260 frames a second on an M3 Max. Anything counted in ticks finishes sooner. |
| Loading screen | About 8 seconds. | About 2 seconds, with more loader threads. |
| Rerunning after you edit a test | Restart the game. | A second or two plus the tests' own time, in a game kept open with `--stay`. |
| A test that hangs | The runner waits for it forever. | It fails after 30 seconds, names what it was waiting for, and the next test starts. |
| A Lua error | The debug error handler stops the game until you notice. | The run ends at once and prints the stack trace. |
| Multiplayer | Host a server, start a second game, and join it. | `--mp`. |

You also don't have to run everything. `TESTS=<prefix>` picks tests by name, `--failed` reruns only what failed last time, and `--changed` runs the tests that cover the files your branch changed, committed or not, using a map from your files to your tests that you keep in the harness's config. When a test fails, the run names the changed files that reach it and the commits that touched them.

### It tests multiplayer on one computer

Multiplayer is where mods break quietly. Each player's game holds its own copy of the world, and the server holds another. A mod that changes one copy without telling the others works fine in single player and goes wrong on a server. `--mp` starts a dedicated server and a client that joins it as admin, on the same computer, and runs the same tests.

The test library's helpers (setting the clock, sandbox options, skills, giving items) change the client's copy and the server's, so a test written once runs in both modes. What only the server can do goes in named handlers in your dev mod's server Lua, which tests call with `T.server`. After each test, wherever a square changed, the harness compares the client's copy of it with the server's and reports each one that still disagrees as a `DESYNC`. A separate script, `dev/validate-server.sh`, boots a dedicated server with only your mod and fails if the mod logged an error while it loaded.

### Every test starts from the same world

A test that passes alone and fails after another sends you hunting in the wrong place, so the harness keeps tests apart. Between tests it resets the character: full health, empty inventory, nothing worn or held, skills restored, back on its starting square. Within a test, every helper that changes something records how to undo it (the clock, sandbox options, the power grid, the tiles, benches and vehicles a test placed), and the undos run when the test ends, pass or fail.

Then it checks. After each test the harness compares the world around the character, the character, the sandbox options and the clock with how they were before, and a test that left something behind fails, naming what it left. The world itself is held still: no zombies, and none of the random furnishing the game does when a building first loads (generators in garages, crash sites, parked cars, rats), so no test meets an object nobody placed. In multiplayer the harness also waits for the server to confirm skills, recipes and daylight before a test reads them.

### It helps you chase a flaky test

`REPEAT=20` runs the selection 20 times in one game and counts each test's passes and failures. `ORDER=shuffle` runs tests in a random order and prints the seed, so `ORDER=shuffle:<seed>` repeats that exact order. Each run also prints the slowest tests and, in multiplayer, how long each spent waiting on the server; `TRACE=1` breaks a run's time down by what each test waited on and by every server call's legs, and writes a timeline you can open in Perfetto.

### It's built for AI coding assistants too

An assistant left alone with a test suite tends to rerun the same failing run hoping for a different answer. The harness won't let it: a run whose tests, settings and files haven't changed since its last verdict prints that verdict instead of starting the game, and after a test fails three runs in a row the script says to stop rerunning and change the approach. The static check runs before every game, so a typo costs seconds instead of a game start. Several assistants editing at once share the one game through the lock.

### It checks the mod before the game starts

`dev/static-check.sh` compiles every Lua file with the game's own compiler and cross-checks the mod against the installed game in about a second: translation keys and files in every language, item, recipe and sandbox option scripts, textures, requires, and every global, method and event name the Lua uses against what the game's Java and Lua define. These are the mistakes the game shows only as a key on screen, an invisible item or a nil error when the line finally runs. A mod adds its own rules as Python plugins. [The static check](docs/static-check.md) lists every rule.

### It runs more than tests

A mod can register its own modes, each a `--<mode>` flag that starts the scenario, runs the mod's code and quits. Renewable Energy and Hearing Aid use them to take the screenshots for their Workshop pages, with the weather held clear so the same shot looks the same tomorrow. The harness's [capture library](docs/adopting.md#capture-modes) shoots UI on black and on white to recover its transparency, crops each shot into named images, and reshoots one group of them without touching the rest.

## Quick start

You need macOS, Project Zomboid Build 42 installed through Steam, and a Java JDK of any version from 8 on, because the game's bundled Java can't compile the launchers.

1. Add the harness to your mod's repository:

    ```sh
    git submodule add https://github.com/CalebFenton/PZ_DevHarness.git dev/harness
    ```

2. Give the harness a `dev/harness.conf`, three one-line entry scripts and a dev mod that holds your debug scenario and tests. [Adopting PZ_DevHarness](docs/adopting.md) shows each file.

3. Run every test, then quit:

    ```sh
    dev/run-debug-client.sh --test
    ```

    The run ends with `<TAG> DONE passed=<n> failed=0 skipped=<n>` and exits 0.

4. Before a release, run the same tests against a dedicated server:

    ```sh
    dev/run-debug-client.sh --test --mp
    ```

5. While you work, batch your edits, committing each change on its own, then run the tests they reach once:

    ```sh
    dev/run-debug-client.sh --test --changed
    ```

## Documentation

- [Adopting PZ_DevHarness](docs/adopting.md): the conf file, entry scripts, dev mod, and the test library's functions.
- [The static check](docs/static-check.md): every rule, the conf keys, and how a mod adds its own rules.
- [Running tests and modes](docs/running.md): every flag and environment variable, the console lines a run prints, the leak check, and what each speedup costs.
- [Debugging with the harness](docs/debugging.md): which run to reach for when, and how to read a failure.
- [Multiplayer](docs/multiplayer.md): how `--mp` works, the server channel, two-sided fixtures, and what a multiplayer client can't do.
- [Writing a mod's Workshop page](docs/workshop-page.md): what players look for, the voice, the description's sections in order, the gallery, and the scripts that turn the README into `workshop.txt` and upload the gallery.
- [`TestLib.lua`](mod/42/media/lua/client/PZHarness/TestLib.lua): the test spec, the restore stack, and the rules that keep each test independent of the ones before it.
