# Debugging with the harness

Which run to reach for, and how to read a failure, so a change takes a handful of game runs
rather than dozens. [running.md](running.md) describes every flag and line named here.

## What to run when

1. After every edit, the mod's static check, if it has one (it takes seconds and needs no game).
2. While you work on a change, a kept game and only the tests it touches:

    ```sh
    dev/run-debug-client.sh --test --stay --changed          # the tests TEST_MAP gives for your changes
    TESTS=mymod_craft_ dev/run-debug-client.sh --test --stay # or name them
    ```

    Add `--mp` when the change touches what the server does or sends. A kept game reloads only
    the conf's `RELOAD_FILES` (test files and server handler files); a change to anything else
    restarts it, which the script does on its own.
3. Once, before you commit, the whole suite in fresh games, in both modes:

    ```sh
    dev/run-debug-client.sh --test
    dev/run-debug-client.sh --test --mp
    ```

## A test fails

1. Read the `FAIL` line's reasons, the `LEAK` and `DESYNC` lines above it, and the log whose path
   the script prints, before changing anything. The reasons name what was missing, what the
   server answered, the action that cleared the queue, or what a stopped test was waiting on.
2. If that doesn't explain it, add one diagnostic (an `expect` with the value in its message, or
   a `print`) and rerun only the failures: `dev/run-debug-client.sh --test --stay --failed`.
3. Fix, then rerun the failures once more, then the suite before you commit.

## It passes alone and fails in the suite

Something an earlier test left behind, or the order, changes it.

1. Read the `LEAK` and `DESYNC` lines of the full run. With `LEAKS=fail`, the default, the test
   that left something behind fails itself, so it is usually the first failure in the run, not
   the one you were looking at.
2. Change the order rather than guessing: `ORDER=reverse` or `ORDER=shuffle`, with the narrowest
   `TESTS` that still fails. A shuffle prints its seed; `ORDER=shuffle:<seed>` repeats it.
3. Never bisect by hand in a kept game. What every earlier run built stays in its world, so
   each run there starts somewhere new, and a result there says little about a fresh game. The
   kept game prints `DIRTY` lines for what its last run left behind; start a fresh game (leave
   out `--stay`) when it does.

## It fails now and then

`REPEAT=<n>` runs the selection n times in one game and prints each test's passes and failures:

```sh
REPEAT=20 TESTS=mymod_world_trailer_ dev/run-debug-client.sh --test --stay
```

Add `ORDER=shuffle` to mix the order between rounds as well.

## Gotchas

- A timed action that turns invalid or is refused stops, and that empties the character's whole
  action queue, the test's later waits and steps included. The harness fails the test at once,
  naming the action that was running, and skips validate, which would read what the lost steps
  never made. Look at why that action refused, such as its `isValid` or a skill check.
- A server handler's answer reaches the test exactly as returned: `false`, `0` and `nil` arrive as
  themselves, so check them before you index them.
- In debug mode a Lua error stops the game in its error handler, `pcall` or not, and the run ends
  there. A validate that indexes something a failed step never made ends the whole run, so guard
  every value a step might not have set (`T.need` in run, a nil check in validate).
- The server sends an object it adds to a square, and later changes to it, by its place in the
  square's list of objects. A client copy whose square holds a different list, such as after an
  object came and went quickly, applies the change to the wrong object or none: that shows as a
  `DESYNC` line on that square.
- A `LEAK` on an object nobody's test touches, which changes on both sides as game time passes,
  is the world rather than a test. The leak check already leaves out crops, erosion and grass; add
  the dev mod's own such sprites to its `leakIgnore` setting rather than switching the check off.
- A `--test` world doesn't populate itself ([a quiet world](running.md#a-quiet-world)): no
  generators, cars, survivor houses or other stories appear on their own. A test that needs one of
  those places it. A world object nobody's test placed, or a test that passes only with a vanilla
  generator or car nearby, means a mod's sandbox settings turned some of that back on, or the
  mod's own code placed it.
