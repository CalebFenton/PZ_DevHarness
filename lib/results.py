#!/usr/bin/env python3
"""The one reader of a --test run's result lines (client/PZHarness/Schedule.lua and Report.lua
write them; docs/running.md lists them), for bin/run-client.sh and lib/tests.py. Each line the game
logs ends "> <text>", after the logger's own prefix.

    results.py counts <log> <tag>             the DONE line's "passed=<n> failed=<n> skipped=<n>"
    results.py times <log> <tag> <at> <mode>  a RUNS_TESTS_LOG line per timed PASS, FAIL or SKIP line
    results.py verdict <log> <tag>            the run's verdict from its DONE line; exits 1 on FAIL
"""
from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field

DONE = re.compile(r"DONE passed=(\d+) failed=(\d+) skipped=(\d+)$")
TOOK = re.compile(r"\(([0-9.]+) s\)$")


@dataclass
class Results:
    started: bool = False
    # The last DONE line's passed, failed and skipped, or None without one.
    done: tuple[int, int, int] | None = None
    # (name, status, seconds) per PASS, FAIL or SKIP line with its time: a test REPEAT runs n
    # times has n.
    timed: list[tuple[str, str, str]] = field(default_factory=list)
    # The tests that failed, or were running when the game stopped; a FAIL line for a name no
    # TEST line announced, such as a call outside any test, isn't a test.
    failed: set[str] = field(default_factory=set)


def parse(path, tag):
    results = Results()
    ran, current = set(), None
    mark = f"> {tag} "
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except FileNotFoundError:
        return results
    for line in lines:
        at = line.find("> TEST: ")
        if at >= 0:
            current = line[at + 8:]
            ran.add(current)
            continue
        at = line.find(mark)
        if at < 0:
            continue
        text = line[at + len(mark):]
        kind, _, rest = text.partition(" ")
        if kind == "START":
            results.started = True
        elif kind == "DONE":
            done = DONE.match(text)
            if done:
                results.done = tuple(int(n) for n in done.groups())
        elif kind in ("PASS", "FAIL", "SKIP"):
            name = re.split(r"[: ]", rest, maxsplit=1)[0]
            took = TOOK.search(text)
            if took:
                results.timed.append((name, kind.lower(), took.group(1)))
            if kind == "FAIL" and name in ran:
                results.failed.add(name)
            if kind == "PASS" or (kind == "FAIL" and name == current):
                current = None
    if results.done is None and current:
        results.failed.add(current)
    return results


def main(argv):
    command, log, tag = argv[1], argv[2], argv[3]
    results = parse(log, tag)
    if command == "counts":
        if results.done:
            print("passed=%d failed=%d skipped=%d" % results.done)
    elif command == "times":
        at, mode = argv[4], argv[5]
        for name, status, seconds in results.timed:
            print(f"{at} mode={mode} test={name} status={status} seconds={seconds}")
    else:
        passed, failed, skipped = results.done or (0, 1, 0)
        if passed == 0 and failed == 0:
            print(f"FAIL: no test ran in this mode ({skipped} skipped)")
        elif passed == 0 or failed > 0:
            print("FAIL: not every test passed")
        else:
            print("PASS")
            return 0
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
