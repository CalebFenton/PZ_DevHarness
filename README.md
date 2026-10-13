# PZ_DevHarness

In-game tests for Project Zomboid Build 42 mods, unattended, in single player and multiplayer, and fast enough that you'll run them after every change instead of promising yourself you'll run them before release.

## Quick start

You need macOS, Project Zomboid Build 42 installed through Steam, and a JDK of any version from 8 on, because the game's bundled Java has no `javac`.

1. Add the harness to your mod's repository:

    ```sh
    git submodule add https://github.com/CalebFenton/PZ_DevHarness.git dev/harness
    ```

2. Give the harness a `dev/harness.conf`, two one-line entry scripts and a dev mod that holds your debug scenario and tests. [Adopting PZ_DevHarness](docs/adopting.md) shows each file.

3. Run every test, then quit:

    ```sh
    dev/run-debug-client.sh --test
    ```

    The run ends with `<TAG> DONE passed=<n> failed=0 skipped=<n>` and exits 0. Any failed test, Lua error or hung test makes it exit 1.

4. Run the same tests against a dedicated server, with a client that joins it:

    ```sh
    dev/run-debug-client.sh --test --mp
    ```

5. While you work on a few tests, keep the game open so each rerun skips the startup:

    ```sh
    TESTS=mymod_craft_ dev/run-debug-client.sh --test --stay
    ```

## What this does

Project Zomboid ships a timed-action test runner in its debug menu. You launch the game, load a world, open **Debug** > **Dev** > **Unit Tests** > **Timed Actions**, select **Run All Tests**, and watch your character perform each test, with a one-second pause after each one so you can read the result. PZ_DevHarness drives that same kind of test with no hands. One command starts the game in debug mode without Steam, in a throwaway cache folder, with three mods loaded: your published mod, your dev mod and the harness mod. It starts your debug scenario, runs the tests, prints each verdict with its reasons, quits, and sets the exit code. Your tests, scenario and fixtures live in the dev mod, which is never uploaded, so the mod your players download carries game code only.

A test is a Lua spec registered with `T.test(name, spec)`. It queues the same timed actions a player would, then checks literal values. Between tests the harness resets the character and the world: full health, empty inventory, nothing worn or held, the clock back to the mod's chosen hour, perks restored, and the character back in the middle of its starting square. Within a test, every setter pushes its own undo: the sandbox options, the clock, the game speed, the power grid, darkness, perks, item changes, and the tiles, benches and vehicles a test placed. The undos run when the test ends, pass or fail. The last test sees the same world as the first, so a failure points at the test that failed rather than at whatever ran before it.

Multiplayer is where mods break quietly. Each player's game holds a copy of the world, and a mod that changes the copy on one side without telling the other works in single player and fails on a server. `--mp` boots a dedicated server, joins a client to it as admin, and runs the same tests. The library's fixtures act on both copies, and server-only work goes through named handlers that tests call with `T.server`.

## Why it's fast

The vanilla debug-menu runner is fine for watching one test. The following table compares the two over a whole suite:

| | Vanilla debug menu | PZ_DevHarness |
| --- | --- | --- |
| Starting a run | Launch through Steam, load a world, click through three menus. | One command. |
| Between tests | A one-second pause so you can read the result. | The next tick. |
| Frame rate | Your frame cap, 60 frames a second by default. | Uncapped, about 260 frames a second on an M3 Max. Anything counted in ticks finishes sooner. |
| Loading screen | About 8 seconds waiting on 4 asset loader threads. | About 2 seconds on up to 12 threads. |
| Rerunning after you edit a test | Restart the game. | Under a second plus the tests' own time, in a game kept open with `--stay`. |
| A test that hangs | The runner waits for it forever. | It fails after 30 seconds of real time, names what it was waiting for, and the next test starts. |
| A Lua error | The debug error handler stops the game until you notice. | The run ends at once and prints the stack trace. |
| Multiplayer | Host a server, start a second game, and join it. | `--mp`. |

## What keeps runs repeatable

A fast run is only worth having if the same tests give the same result every time. Several harness behaviors take run-to-run noise out of the game, so a failure comes from the mod or the test:

- Every cold run starts a new world with no zombies, since the server's sandbox sets `Zombies = 6`, the "None" setting. The survivor gets teleported, stripped, healed and re-skilled before every test without one undead interruption.
- Tests wait on the condition they need with `waitUntil`, never for a fixed number of frames, so an uncapped frame rate changes how long a run takes, not what it checks.
- Screenshot modes can clear the sky and hold it clear, so the same shot looks the same tomorrow when the in-game weather would have rolled in fog.
- In multiplayer, the harness waits for the server's confirmation of perks, recipes and daylight before a test reads them, and it waits out a race in the game's own vehicle networking that drops a part change made in the first few hundred milliseconds after a vehicle reaches a client.
- Only one game runs at a time across every mod that uses the harness. A shared lock queues the next run instead of letting two games fight over ports, cache folders and your keyboard.
- Runs are silent. The harness sets every volume to 0 in its own cache, so your speakers keep your settings when you play by hand.

## Documentation

- [Adopting PZ_DevHarness](docs/adopting.md): the conf file, entry scripts, dev mod, and the test library's functions.
- [Running tests and modes](docs/running.md): every flag and environment variable, the console lines a run prints, and what each speedup costs.
- [Multiplayer](docs/multiplayer.md): how `--mp` works, the server channel, two-sided fixtures, and what a multiplayer client can't do.
- [`TestLib.lua`](mod/42/media/lua/client/PZHarness/TestLib.lua): the test spec, the restore stack, and the rules that keep each test independent of the ones before it.
