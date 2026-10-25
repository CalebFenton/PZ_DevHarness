# PZ_DevHarness

## Commands

- The harness has no suite of its own; the mods that use it are the test. After a batch of changes, in each mod that uses it: `dev/static-check.sh`, then `dev/run-debug-client.sh --test --changed`, and `--test --mp` too after a change to the runner, the server channel or a multiplayer start. Also `dev/validate-server.sh` after a change to the server's start, and `art/models/make.sh` in every mod that has one after a change under `lib/art/` or to `lib/blender.sh`: the rebuild writes the same bytes from unchanged sources, so `git status` must show only the art changes you meant.

## Rules

- Several mods use this repository as their `dev/harness` submodule. Keep it free of any one mod's names, paths and settings: those come from the mod's `dev/harness.conf`, its dev mod's `PZHarness.register` (scenario and modes) and its `PZHarness.registerTests` (test settings and hooks, from shared Lua).
- A change to a conf key, a setting, a flag, a console line or a test library function updates every mod that uses the harness in the same change, and the doc that describes it: `docs/adopting.md` for the conf and the library, `docs/running.md` for flags, environment and console lines, `docs/debugging.md` for how to spend runs, `docs/art.md` for the art library.
- A change reaches a mod only through its submodule pointer: push the harness, then in each mod `git -C dev/harness pull --ff-only origin master` and commit the pointer.
- Never edit `bin/` or `lib/` while one of their runs is going: bash reads a script as it runs, and an edit under it breaks that run.

## Read when needed

- Before changing the runner, the leak check or the server channel, read `mod/42/media/lua/client/PZHarness/TestLib.lua`'s header and `docs/multiplayer.md`: the rules that keep each test independent, and what a multiplayer client can and can't do.
