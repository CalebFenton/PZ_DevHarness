"""Cross-checks a mod against the installed game, without running it.

    python3 check.py --game <game Java folder> --api <GameProbe API file> --cache <folder>
                     --name <mod folder name> [--library <mod folder>]... [--plugin <file>]...
                     [--all-languages] <mod root>...

bin/static-check.sh runs it after GameProbe has compiled every Lua file, with what the mod's
dev/harness.conf says. The roots are the published mod's version folders, its mod.info's first,
then the dev mod's and the harness mod's (moddata.Mod); each --library is a library mod's folder,
from the conf's LIBRARY_MODS in load order. The checks are the rules_*.py modules' in the order
imported below, then tiles.py's, then each plugin's in the order given.
"""
import argparse
import importlib.util
import os
import sys

import gamedata
import moddata
# Importing a rule module registers its checks, so this order is the order they run in.
import rules_translations  # noqa: F401
import rules_scripts  # noqa: F401
import rules_sandbox  # noqa: F401
import rules_lua  # noqa: F401
import tiles  # noqa: F401


def main(argv):
    parser = argparse.ArgumentParser(usage=__doc__.split("\n\n")[1])
    parser.add_argument("--game", required=True)
    parser.add_argument("--api", required=True)
    parser.add_argument("--cache", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--library", action="append", default=[])
    parser.add_argument("--plugin", action="append", default=[])
    parser.add_argument("--all-languages", action="store_true")
    parser.add_argument("roots", nargs="+")
    args = parser.parse_args(argv)

    for path in args.plugin:
        name = os.path.splitext(os.path.basename(path))[0]
        spec = importlib.util.spec_from_file_location(name, path)
        plugin = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(plugin)

    roots = [os.path.abspath(r) for r in args.roots]
    # Messages name files from the folder every root is in; a library's from there too, by a path
    # out of it.
    report = moddata.Report(os.path.commonpath(roots) if len(roots) > 1 else os.path.dirname(roots[0]))
    mod = moddata.Mod(roots, args.name, report, args.all_languages, [os.path.abspath(f) for f in args.library])
    # An empty scan means the paths are wrong, not that the mod is clean.
    if not mod.lua:
        report.fail("no-input", roots[0], None, "found no Lua files under %s" % ", ".join(roots))
    game = gamedata.Game(args.game, args.api, args.cache)
    for function in moddata.CHECKS:
        function(mod, game, report)
    return report.finish()


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(main(sys.argv[1:]))
