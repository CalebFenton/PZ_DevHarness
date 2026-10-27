#!/usr/bin/env python3
"""The result lines of a --test run in its console log, read in one place for bin/run-client.sh
and lib/tests.py. client/PZHarness/Report.lua writes them; docs/running.md lists them. Each line
the game logs ends "> <text>", after the logger's own prefix.

    results.py counts <log> <tag>             the DONE line's "passed=<n> failed=<n> skipped=<n>"
    results.py times <log> <tag> <at> <mode>  a RUNS_TESTS_LOG line per PASS, FAIL or SKIP line
    results.py verdict <log> <tag>            the run's verdict from its DONE line; exits 1 on FAIL
"""
from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field

DONE = re.compile(r"DONE passed=(\d+) failed=(\d+) skipped=(\d+)$")
TOOK = re.compile(r"\(([0-9.]+) s\)$")


@dataclass
class Test:
    name: str
    status: str  # pass, fail or skip
    seconds: str | None  # as the line gives it; None on a line without the time


@dataclass
class Results:
    started: bool = False
    # The last DONE line's passed, failed and skipped, or None without one.
    done: tuple[int, int, int] | None = None
    # One per PASS, FAIL or SKIP line, in order: a test REPEAT runs n times has n.
    tests: list[Test] = field(default_factory=list)
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
            results.tests.append(Test(name, kind.lower(), took.group(1) if took else None))
            if kind == "FAIL" and name in ran:
                results.failed.add(name)
            if kind == "PASS" or (kind == "FAIL" and name == current):
                current = None
    if results.done is None and current:
        results.failed.add(current)
    return results


def counts(results):
    if results.done is None:
        return ""
    return "passed=%d failed=%d skipped=%d" % results.done


def verdict(results):
    """("PASS", 0) once at least one test passed and none failed, else the failure and 1."""
    if results.done is None:
        return "FAIL: not every test passed", 1
    passed, failed, skipped = results.done
    if passed == 0 and failed == 0:
        return f"FAIL: no test ran in this mode ({skipped} skipped)", 1
    if passed == 0 or failed > 0:
        return "FAIL: not every test passed", 1
    return "PASS", 0


def main(argv):
    command, log, tag = argv[1], argv[2], argv[3]
    results = parse(log, tag)
    if command == "counts":
        print(counts(results))
    elif command == "times":
        at, mode = argv[4], argv[5]
        for test in results.tests:
            if test.seconds is not None:
                print(f"{at} mode={mode} test={test.name} status={test.status} seconds={test.seconds}")
    elif command == "verdict":
        line, status = verdict(results)
        print(line)
        return status
    else:
        print(f"results.py: unknown command {command}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
