# Debugging with the harness

Which run to reach for, and how to read a failure, so a change takes a handful of game runs
rather than dozens. A game run is the most expensive step of a change: about 20 seconds of
starting and quitting before and after the tests, and more with `--mp`. So batch the changes
and spend one run on them, and make each run able to tell you something the last one didn't.
[running.md](running.md) describes every flag and line named here.

## What to run when

1. After every edit, `dev/static-check.sh` ([static-check.md](static-check.md); it takes seconds
   and needs no game). The conf's `PRECHECK` runs it before every game run as well.
2. Make a batch of changes, committing each logical change on its own, then spend one run on the
   tests the whole batch reaches:

    ```sh
    dev/run-debug-client.sh --test --changed          # the tests TEST_MAP gives for the batch
    TESTS=mymod_craft_ dev/run-debug-client.sh --test # or name them
    ```

    `--changed` counts everything since the branch left its upstream, commits and uncommitted
    work alike, and prints the base it used; `SINCE=<ref>` sets another. Batches run in single
    player. Don't run the game after each edit.
3. Once, before you push or merge, the whole suite in a fresh game:

    ```sh
    dev/run-debug-client.sh --test
    ```

4. Before a release, the whole suite against a dedicated server too, which costs about three times
   the single player run:

    ```sh
    dev/run-debug-client.sh --test --mp
    ```

`--stay` keeps the game open and reruns in it, skipping the start; it reloads only the conf's
`RELOAD_FILES` and keeps what earlier runs built in its world
([running.md](running.md#why-it-is-fast-and-what-that-costs)). It suits rerunning a test file
you are editing many times over, not the batch's run, whose verdict should come from a fresh game.

The script won't repeat a run whose selection, settings and files haven't changed since it last
got a verdict: it prints that verdict instead ([repeats](running.md#repeats)). Set `RERUN=1` only
when the game rather than a test failed, such as a crash before the tests started.

## Several agents, one game

Only one game runs at a time; every other run waits for the lock, and each fresh one pays the
game's start. Let the agents that edit run the static check, and have one agent run the game for
all of them, with everyone's changes in one run.

## A test fails

1. Read the `FAIL` line's reasons, the `LEAK` and `DESYNC` lines above it, and the log whose path
   the script prints, before changing anything. The reasons name what was missing, what the
   server answered, the action that cleared the queue, or what a stopped test was waiting on.
2. Find the change that broke it. The run prints a `suspects <test>: ...` line per failed test
   ([suspects](running.md#suspects)): the batch's changed files that reach it, each with the
   commits that touched it and `uncommitted` if it has uncommitted changes. Read those commits'
   diffs first; reading costs less than a run. If they don't settle it, run only that test,
   `TESTS==<name> dev/run-debug-client.sh --test`, at the suspect commits, oldest first, until it
   fails. A test with no suspect broke before the base, or `TEST_MAP` misses the file that reaches
   it.
3. If that doesn't explain it, write down the explanations that fit, add the one diagnostic that
   tells them apart (an `expect` with the value in its message, or a `print`), and rerun only the
   failures: `dev/run-debug-client.sh --test --failed`.
4. Fix, then rerun the failures once more, then the suite before you push or merge.
5. When the script says a test has failed three runs in a row, stop rerunning. Write down what
   each run ruled out and change the approach: a different diagnostic, a smaller test, or reading
   the game's code (decompiled Java and its Lua) for what the step really does.

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
REPEAT=20 TESTS=mymod_world_trailer_ dev/run-debug-client.sh --test
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
