# PZ_DevHarness

## Commands

- The harness has no suite of its own; a mod that uses it is the test. From that mod's repository, run `dev/run-debug-client.sh --test` and `dev/run-debug-client.sh --test --mp`, plus `dev/validate-server.sh` after a change to the server's start.

## Rules

- Several mods use this repository as their `dev/harness` submodule. Keep it free of any one mod's names, paths and settings: those come from the mod's `dev/harness.conf` and its dev mod's `PZHarness.register` settings.
- A change to a conf key, a setting, a flag, a console line or a test library function updates every mod that uses the harness in the same change, and the doc that describes it: `docs/adopting.md` for the conf and the library, `docs/running.md` for flags, environment and console lines, `docs/debugging.md` for how to spend runs.
- A change reaches a mod only through its submodule pointer: push the harness, then in each mod `git -C dev/harness pull --ff-only origin master` and commit the pointer.
- Never edit `bin/` or `lib/` while one of their runs is going: bash reads a script as it runs, and an edit under it breaks that run.

## Read when needed

- Before changing the runner, the leak check or the server channel, read `mod/42/media/lua/client/PZHarness/TestLib.lua`'s header and `docs/multiplayer.md`: the rules that keep each test independent, and what a multiplayer client can and can't do.
