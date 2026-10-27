#!/usr/bin/env python3
"""Which tests a --test run runs, and which changed files a failed test points at: the conf's
TEST_MAP (docs/adopting.md), --changed's batch, --failed's record and the suspects of a failure
(docs/running.md, "Choosing tests"). lib/harness.sh's tests_py runs it with the conf, and the
batch `batch` printed, in its environment; TEST_MAP is there only when the conf sets it.

    tests.py check | batch | changed | failed <key> | record <key> <log> <tag> <test files>

`changed` and `failed` print what they decided, then a last line "SELECTION=<entries>", and exit 3
when there are no tests to run.
"""
from __future__ import annotations

import fnmatch
import os
import shlex
import subprocess
import sys
from pathlib import Path

import results

# A file's reach when every test runs for it.
EVERY = None
# A file outside the folders TEST_MAP covers.
OUTSIDE = ()
# Runs in a row a test may fail before the script says reruns aren't narrowing it down.
STUCK_RUNS = 3
# What `changed` and `failed` exit with when no test is to run.
NOTHING = 3


class Conf:
    def __init__(self, env):
        self.repo = Path(env["REPO"])
        self.harness = Path(env["HARNESS"])
        self.submodule = self.relative(self.harness)
        self.mod = self.relative(env["MOD_DIR"])
        self.dev_mod = self.relative(env["DEV_MOD_DIR"])
        self.harness_mod = self.relative(env["HARNESS_MOD_DIR"])
        self.has_map = "TEST_MAP" in env
        self.map = []
        for entry in lines(env.get("TEST_MAP", "")):
            glob, _, entries = entry.partition("=")
            self.map.append((glob, [e for e in entries.split(",") if e]))
        self.library_ids = env.get("LIBRARY_IDS", "").split()

    def relative(self, path):
        return os.path.relpath(path, self.repo)

    def under(self, path, folder):
        return path.startswith(folder + "/")

    def is_test_file(self, path):
        name = path.rsplit("/", 1)[-1]
        return self.under(path, self.dev_mod) and name.endswith(".lua") and "Tests" in name

    def matches(self, path):
        """TEST_MAP's indexes of the globs matching `path`, relative to the repository; None outside
        the folders it covers."""
        if not any(self.under(path, folder) for folder in (self.mod, self.dev_mod, self.harness_mod)):
            return None
        return [i for i, (glob, _) in enumerate(self.map) if fnmatch.fnmatchcase(path, glob)]

    def reach(self, path):
        """OUTSIDE, EVERY, or the sorted entries a change to `path` runs, empty for none: those of
        every glob it matches, and a dev mod test file's own tests as "@<file name>" (TestLib's
        T.test). An unmatched file of the folders TEST_MAP covers reaches every test."""
        if not self.has_map:
            return EVERY if self.matches(path) is not None else OUTSIDE
        found = self.matches(path)
        if found is None:
            return OUTSIDE
        test_file = self.is_test_file(path)
        if not found and not test_file:
            return EVERY
        entries = {e for i in found for e in self.map[i][1]}
        # A deleted test file's tests are gone with it.
        if test_file and (self.repo / path).exists():
            entries.add("@" + path.rsplit("/", 1)[-1])
        return sorted(entries)


def git(directory, *args):
    return subprocess.run(["git", "-C", str(directory), *args], check=True, capture_output=True,
                          text=True).stdout


def git_or_none(directory, *args):
    done = subprocess.run(["git", "-C", str(directory), *args], capture_output=True, text=True)
    return done.stdout.strip() if done.returncode == 0 else None


def lines(text):
    return [line for line in text.splitlines() if line]


def repo_files(conf):
    """Every file of the repository and the harness submodule, tracked or untracked, but not one
    deleted from the working tree and not yet from the index."""
    def present(directory):
        deleted = set(lines(git(directory, "ls-files", "--deleted")))
        return [f for f in lines(git(directory, "ls-files", "--cached", "--others", "--exclude-standard"))
                if f not in deleted]
    return present(conf.repo) + [f"{conf.submodule}/{f}" for f in present(conf.harness)]


def check(conf):
    """Problems with TEST_MAP: a file of the mod or the dev mod that would run every test, or a
    glob that matches none of the files, such as one for a file since renamed. A conf without
    TEST_MAP runs every test for any change, so has nothing to miss."""
    if not conf.has_map:
        return []
    problems, used = [], set()
    for path in repo_files(conf):
        found = conf.matches(path)
        if found is None:
            continue
        used.update(found)
        if not found and not conf.is_test_file(path) and not conf.under(path, conf.harness_mod):
            problems.append(f"TEST_MAP: {path} has no line in dev/harness.conf; add one naming the tests "
                            "that reach it (nothing after = for none)")
    for i, (glob, _) in enumerate(conf.map):
        if i not in used:
            problems.append(f"TEST_MAP: {glob} matches no file; fix or remove its line in dev/harness.conf")
    return problems


def batch(conf, since):
    """What --changed and the suspects of a failure look at: what changed since BATCH_BASE, `since`
    when set, else where the branch left its upstream, else HEAD, which leaves out the branch's
    commits. HARNESS_BASE is the harness commit the repository recorded at BATCH_BASE, so the batch
    has the harness's own commits too, else the harness's HEAD. Both HEADs are kept as the run
    starts, so a commit made during the run isn't counted in it."""
    head = git(conf.repo, "rev-parse", "HEAD").strip()
    harness_head = git(conf.harness, "rev-parse", "HEAD").strip()
    if since:
        base = git_or_none(conf.repo, "rev-parse", "--verify", "--quiet", since + "^{commit}")
        if not base:
            raise SystemExit(f"SINCE={since} names no commit of the repository")
        why = f"SINCE={since}"
    else:
        upstream = git_or_none(conf.repo, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
        base = upstream and git_or_none(conf.repo, "merge-base", "HEAD", upstream)
        why = f"where the branch left {upstream}"
        if not base:
            # A local branch, as an agent's worktree has, covers what it added to the default branch.
            upstream = git_or_none(conf.repo, "rev-parse", "--abbrev-ref", "origin/HEAD")
            base = upstream and git_or_none(conf.repo, "merge-base", "HEAD", upstream)
            why = f"where the branch left {upstream}, having no upstream of its own"
        if not base:
            base = head
            why = "HEAD: the branch has no upstream and the repository no origin/HEAD, so SINCE=<ref> adds its commits"
    harness_base = git_or_none(conf.repo, "rev-parse", "--verify", "--quiet", f"{base}:{conf.submodule}")
    if not harness_base or git_or_none(conf.harness, "cat-file", "-e", harness_base + "^{commit}") is None:
        harness_base = harness_head
    said = f"{git(conf.repo, 'rev-parse', '--short', base).strip()} ({why})"
    return {"BATCH_BASE": base, "BATCH_HEAD": head, "HARNESS_BASE": harness_base,
            "HARNESS_HEAD": harness_head, "BATCH_BASE_SAID": said}


def changed_files(conf, env):
    """Every file changed in the batch, committed, staged, unstaged or untracked, relative to the
    repository, the harness submodule's own changes included."""
    files = set(lines(git(conf.repo, "diff", "--name-only", env["BATCH_BASE"])))
    files.update(lines(git(conf.repo, "ls-files", "--others", "--exclude-standard")))
    harness = lines(git(conf.harness, "diff", "--name-only", env["HARNESS_BASE"]))
    harness += lines(git(conf.harness, "ls-files", "--others", "--exclude-standard"))
    files.update(f"{conf.submodule}/{f}" for f in harness)
    return sorted(files)


def file_history(conf, env, path):
    """The batch's commits that touched `path`, newest first, as '<hash> "<subject>"', and
    "uncommitted" if it differs from HEAD or is untracked."""
    directory, base, head, file = conf.repo, env["BATCH_BASE"], env["BATCH_HEAD"], path
    if conf.under(path, conf.submodule):
        directory, base, head = conf.harness, env["HARNESS_BASE"], env["HARNESS_HEAD"]
        file = path[len(conf.submodule) + 1:]
    history = [line.rstrip() + '"' for line in
               lines(git(directory, "log", "--format=%h \"%<(60,trunc)%s", f"{base}..{head}", "--", file))]
    if git(directory, "status", "--porcelain", "--", file).strip():
        history.append("uncommitted")
    return history


def select_changed(conf, env):
    """The selection for the batch's changed files, saying why for each; None when nothing is to
    run, "" for every test. A library's repository records no batch base for this one, so its
    changes are not in the batch."""
    print(f"--changed: base {env['BATCH_BASE_SAID']}")
    if conf.library_ids:
        print(f"--changed: changes to the libraries ({' '.join(conf.library_ids)}) are not in the batch; "
              "after one, run every test")
    picked, everything, relevant = set(), False, False
    for path in changed_files(conf, env):
        reach = conf.reach(path)
        if reach is OUTSIDE:
            continue
        relevant = True
        if reach is EVERY:
            print(f"--changed: {path}: no TEST_MAP glob covers it, so every test runs")
            everything = True
        else:
            print(f"--changed: {path}: {','.join(reach) or 'no tests'}")
            picked.update(reach)
    if not relevant:
        print("--changed: nothing under the mods changed since the base; no tests to run")
        return None
    if everything:
        return ""
    if not picked:
        print("--changed: no test covers the changed files; no tests to run")
        return None
    selection = ",".join(sorted(picked))
    print(f"--changed: running {selection}")
    return selection


def failed_record(path, key):
    """The last record of runs of kind `key` in RUNS_FAILED: test name to how many such runs in a
    row it has failed; None without one."""
    path = Path(path)
    found = [line for line in path.read_text().splitlines() if line.startswith(key + " ")] if path.exists() else []
    if not found:
        return None
    entries = (entry.rpartition(":") for entry in found[-1][len(key) + 1:].split(",") if entry)
    return {name: int(runs) for name, _, runs in entries}


def select_failed(conf, env, key):
    """The exact names of the tests that failed in the last run of kind `key`, as a selection."""
    record = failed_record(env["RUNS_FAILED"], key)
    if record is None:
        raise SystemExit(f"--failed: no {key} run has been recorded in {conf.relative(env['RUNS_FAILED'])} yet")
    if not record:
        print(f"--failed: nothing failed in the last {key} run; no tests to run")
        return None
    names = list(record)
    print(f"--failed: rerunning what failed in the last {key} run: {', '.join(names)}")
    return ",".join("=" + name for name in names)


def reaches(entry, name, test_files):
    if entry.startswith("="):
        return entry[1:] == name
    if entry.startswith("@"):
        return test_files.get(name) == entry[1:]
    return name.startswith(entry)


def print_suspects(conf, env, names, test_files):
    """For each failed test, "suspects <test>: <file> (<commits>); ...": the batch's changed files
    that reach it, each with its commits, newest first. `test_files` names the file that registered
    each test, for "@<file>" entries."""
    changed = [(path, conf.reach(path)) for path in changed_files(conf, env)]
    print(f"suspects: the files changed since {env['BATCH_BASE_SAID']} that reach each failed test")
    for name in names:
        hits = []
        for path, reach in changed:
            if reach is OUTSIDE or (reach is not EVERY and not any(reaches(e, name, test_files) for e in reach)):
                continue
            history = ", ".join(file_history(conf, env, path))
            hits.append(f"{path} ({history or 'no commit'})")
        print(f"suspects {name}: {'; '.join(hits) or 'none of the changed files reach it'}")


def read_test_files(path):
    """The file each test was registered from, as the runner wrote them (Run.writeTestFiles)."""
    files = {}
    try:
        for line in Path(path).read_text().splitlines():
            name, _, file = line.partition("\t")
            files[name] = file
    except FileNotFoundError:
        pass
    return files


def record(conf, env, key, log, tag, test_files_path):
    """Records the tests that failed in the run, or were running when it stopped, for the next
    --failed run of kind `key`, each with how many such runs in a row it has failed, then prints
    them and their suspects. A run that never started its tests leaves the last record alone."""
    run = results.parse(log, tag)
    if not run.started:
        return
    names = sorted(run.failed)
    previous = failed_record(env["RUNS_FAILED"], key) or {}
    counts = {name: previous.get(name, 0) + 1 for name in names}
    path = Path(env["RUNS_FAILED"])
    kept = [line for line in path.read_text().splitlines() if not line.startswith(key + " ")] \
        if path.exists() else []
    kept.append(f"{key} " + ",".join(f"{name}:{runs}" for name, runs in counts.items()))
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text("\n".join(kept) + "\n")
    tmp.replace(path)
    if names:
        print(f"--failed reruns: {', '.join(names)}")
        print_suspects(conf, env, names, read_test_files(test_files_path))
    stuck = [f"{name} ({runs})" for name, runs in counts.items() if runs >= STUCK_RUNS]
    if stuck:
        print(f"failed {STUCK_RUNS} or more runs in a row: {' '.join(stuck)}. Rerunning won't narrow it; "
              f"read {conf.submodule}/docs/debugging.md and change approach first")


def main(argv):
    env = os.environ
    conf = Conf(env)
    command = argv[1]
    if command == "batch":
        for name, value in batch(conf, env.get("SINCE", "")).items():
            print(f"{name}={shlex.quote(value)}")
        return 0
    if command == "record":
        record(conf, env, *argv[2:6])
        return 0
    if command == "failed":
        selection = select_failed(conf, env, argv[2])
    else:
        problems = check(conf)
        for problem in problems:
            print(problem, file=sys.stderr)
        if problems or command == "check":
            return 2 if problems else 0
        selection = select_changed(conf, env)
    if selection is None:
        return NOTHING
    print(f"SELECTION={selection}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
