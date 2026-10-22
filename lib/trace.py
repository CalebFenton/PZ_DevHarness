#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Reports where a TRACE=1 --test run's time went, from the trace the runner wrote
(PZHarness/Trace.lua), and writes it as a Chrome trace for https://ui.perfetto.dev. run-client.sh
runs it after a traced run; by hand:

    dev/harness/lib/trace.py <cache dir>/Lua/PZHarnessTrace.txt <out.json>

A test's time goes to whatever heads its action queue. While that is a wait for the server's
answer, or the runner's reset and leak check between tests, the time goes to the leg the oldest
request still unanswered is on: on its way to the server, queued there behind earlier requests,
in its handler, on its way back, or held until earlier answers came. Once every answer is in, a
wait still running is waiting on this client: the items or objects the answer promised, or the
next frame. Single player answers within the frame, so all of it is the client's.
"""
import bisect
import json
import sys
from collections import defaultdict

LEGS = ("to the server", "queued on the server", "in the handler", "back to the client", "held for earlier answers")
AFTER = "after the answer"
TOP = 15


def number(field):
    return None if field == "-" else int(field)


def load(path):
    tests, actions, gaps, calls = [], [], [], []
    with open(path, encoding="utf-8") as f:
        for line in f:
            fields = line.rstrip("\n").split("\t")
            kind = fields[0]
            if kind == "test":
                tests.append({"name": fields[1], "start": int(fields[2]), "end": int(fields[3]), "frames": int(fields[4])})
            elif kind == "action":
                actions.append({"test": fields[1], "start": int(fields[2]), "end": int(fields[3]),
                                "frames": int(fields[4]), "what": fields[5]})
            elif kind == "gap":
                gaps.append({"what": fields[1], "start": int(fields[2]), "end": int(fields[3])})
            elif kind == "call":
                times = [number(f) for f in fields[5:11]]
                calls.append({"test": fields[1], "id": int(fields[2]), "kind": fields[3], "name": fields[4],
                              "times": times})
    calls.sort(key=lambda c: c["times"][0])
    return tests, actions, gaps, calls


def leg(call, t):
    """The leg `call` is on at `t`, or None outside sent..delivered. A call single player answered
    in the same frame has only those two times, all of it in the handler."""
    times = call["times"]
    if None in times:
        sent, delivered = times[0], times[5]
        return LEGS[2] if sent <= t < delivered else None
    for i in range(5):
        if times[i] <= t < times[i + 1]:
            return LEGS[i]
    return None


class Calls:
    def __init__(self, calls):
        self.calls = calls
        self.sent = [c["times"][0] for c in calls]
        self.longest = max((c["times"][5] - c["times"][0] for c in calls), default=0)

    def split(self, start, end):
        """Milliseconds of start..end by the leg of the oldest unanswered request, else AFTER."""
        lo = bisect.bisect_left(self.sent, start - self.longest)
        hi = bisect.bisect_left(self.sent, end)
        near = sorted((c for c in self.calls[lo:hi] if c["times"][5] > start), key=lambda c: c["id"])
        out = defaultdict(int)
        for t in range(start, end):
            for call in near:
                part = leg(call, t)
                if part:
                    out[part] += 1
                    break
            else:
                out[AFTER] += 1
        return out


def waits_on_server(what):
    return what.startswith("the server's answer")


def seconds(ms):
    return f"{ms / 1000:7.1f} s"


def legs_line(parts):
    return ", ".join(f"{name} {parts[name] / 1000:.1f}" for name in LEGS + (AFTER,) if parts.get(name))


def percentile(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(p * len(values)))] if values else 0


def report(tests, actions, gaps, calls):
    index = Calls(calls)
    in_tests = sum(t["end"] - t["start"] for t in tests)
    frames = sum(t["frames"] for t in tests)
    print(f"trace: {len(tests)} tests, {in_tests / 1000:.1f} s in them, {frames} frames"
          f" ({frames / max(in_tests, 1) * 1000:.0f} a second)")

    server = defaultdict(int)
    by_what = defaultdict(lambda: [0, 0, 0])
    per_test = defaultdict(lambda: defaultdict(int))
    for a in actions:
        span = a["end"] - a["start"]
        if waits_on_server(a["what"]):
            parts = index.split(a["start"], a["end"])
            for name, ms in parts.items():
                server[name] += ms
                per_test[a["test"]]["server" if name != AFTER else AFTER] += ms
        else:
            per_test[a["test"]][a["what"]] += span
        entry = by_what[a["what"]]
        entry[0] += span
        entry[1] += 1
        entry[2] += a["frames"]
    waited = sum(ms for name, ms in server.items() if name != AFTER)
    print(f"{seconds(waited)} of it waiting on the server: {legs_line(server)}")
    print(f"{seconds(server.get(AFTER, 0))} of it after the server's answer was in, before the wait for it ended")
    print(f"what headed the action queue longest, in total (count, frames):")
    for what, (ms, count, n) in sorted(by_what.items(), key=lambda kv: -kv[1][0])[:TOP]:
        print(f"  {seconds(ms)}  {count:5d} {n:6d}  {what}")

    between = defaultdict(lambda: defaultdict(int))
    for g in gaps:
        for name, ms in index.split(g["start"], g["end"]).items():
            between[g["what"]][name] += ms
    for what, parts in between.items():
        total = sum(parts.values())
        print(f"{seconds(total)} between tests in {what}: {legs_line(parts)}")

    full = [c for c in calls if None not in c["times"]]
    if full:
        print(f"server calls: {len(calls)}; milliseconds per leg, median / 90th percentile / most:")
        for i, name in enumerate(LEGS):
            values = [c["times"][i + 1] - c["times"][i] for c in full]
            print(f"  {name:26s} {percentile(values, 0.5):5d} {percentile(values, 0.9):5d} {max(values):6d}")
        by_name = defaultdict(lambda: [0, 0])
        for c in full:
            by_name[c["name"]][0] += c["times"][5] - c["times"][0]
            by_name[c["name"]][1] += 1
        print("calls by total time from sent to delivered (count):")
        for name, (ms, count) in sorted(by_name.items(), key=lambda kv: -kv[1][0])[:TOP]:
            print(f"  {seconds(ms)}  {count:5d}  {name}")

    print("slowest tests: total = server + after its answers + the rest's largest part")
    for t in sorted(tests, key=lambda t: t["start"] - t["end"])[:TOP]:
        parts = per_test[t["name"]]
        rest = {k: v for k, v in parts.items() if k not in ("server", AFTER)}
        largest = max(rest.items(), key=lambda kv: kv[1], default=("", 0))
        print(f"  {(t['end'] - t['start']) / 1000:5.2f} = {parts['server'] / 1000:.2f} + {parts[AFTER] / 1000:.2f}"
              f" + {largest[1] / 1000:.2f} {largest[0]}  {t['name']}  ({t['frames']} frames)")


def chrome(tests, actions, gaps, calls, out):
    """Tests and gaps on one track, the action queue on the next, each call's legs below."""
    origin = min([t["start"] for t in tests] + [c["times"][0] for c in calls])
    events = [{"ph": "M", "pid": 1, "name": "process_name", "args": {"name": "client"}},
              {"ph": "M", "pid": 1, "tid": 1, "name": "thread_name", "args": {"name": "tests"}},
              {"ph": "M", "pid": 1, "tid": 2, "name": "thread_name", "args": {"name": "action queue"}},
              {"ph": "M", "pid": 2, "name": "process_name", "args": {"name": "server calls"}}]

    def span(pid, tid, name, start, end, args=None):
        events.append({"ph": "X", "pid": pid, "tid": tid, "name": name, "ts": (start - origin) * 1000,
                       "dur": max(end - start, 0) * 1000, "args": args or {}})

    for t in tests:
        span(1, 1, t["name"], t["start"], t["end"], {"frames": t["frames"]})
    for g in gaps:
        span(1, 1, g["what"], g["start"], g["end"])
    for a in actions:
        span(1, 2, a["what"], a["start"], a["end"], {"test": a["test"], "frames": a["frames"]})
    # Overlapping calls each get a free row.
    rows = []
    for c in calls:
        times = c["times"]
        end = times[5] if times[5] is not None else times[0]
        row = next((i for i, busy in enumerate(rows) if busy <= times[0]), len(rows))
        if row == len(rows):
            rows.append(0)
        rows[row] = end
        name = c["name"] if c["name"] != "-" else c["kind"]
        args = {"test": c["test"], "id": c["id"], "kind": c["kind"]}
        if None in times:
            span(2, row + 1, name, times[0], end, args)
            continue
        for i, part in enumerate(LEGS):
            span(2, row + 1, f"{name}: {part}", times[i], times[i + 1], args)
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"traceEvents": events, "displayTimeUnit": "ms"}, f)


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: trace.py <PZHarnessTrace.txt> <out.json>")
    tests, actions, gaps, calls = load(sys.argv[1])
    if not tests:
        sys.exit(f"trace: no test in {sys.argv[1]}")
    report(tests, actions, gaps, calls)
    chrome(tests, actions, gaps, calls, sys.argv[2])
    print(f"trace: {sys.argv[2]} opens in https://ui.perfetto.dev")


if __name__ == "__main__":
    main()
