#!/usr/bin/env python3
"""Where on the vanilla map an item spawns as loot, or where a room type stands (docs/find-loot.md).

    dev/harness/lib/findloot.py [--media <PZ media folder>] [--all] ITEM_REGEX
    dev/harness/lib/findloot.py [--media <PZ media folder>] [--all] --room ROOM

The media folder defaults to the installed game's, which PZ_APP moves as in the harness's scripts.
Everything comes from the game's files, read fresh each run, which takes under a second:
- Loot: the tables under lua/server/Items. Apart from references to other tables they are
  literals, so they are read as such, and a file that ever assigns anything else stops the tool
  rather than being half read. Then the room aliases mergeDistributions adds (SuburbsDistributions
  .fishing = SuburbsDistributions.fishingstorage and the like).
- Rooms: the vanilla map's lotheader files (check/lotheader.py).
- Places: the world map's own labels (worldmap-annotations.lua), towns named through the English
  MapLabel translations.
"""
import argparse
import collections
import glob
import json
import math
import os
import re
import signal
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "check"))
import lotheader  # noqa: E402
import luasource  # noqa: E402
from luasource import KEYWORD, NAME, NUMBER, OP, STRING  # noqa: E402

PZ_APP = os.environ.get("PZ_APP", os.path.expanduser(
    "~/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app/Contents"))
DEFAULT_MEDIA = os.path.join(PZ_APP, "Java", "media")
ITEMS = "lua/server/Items"
# The vanilla world's map folder; the town folders beside it hold only spawn points.
MAP = "maps/Muldraugh, KY"
MAP_LABELS = "lua/shared/Translate/EN/MapLabel.json"
# A landmark further from a building than this names a different place.
LANDMARK_SQUARES = 300
# Buildings listed for each room unless --all.
BUILDINGS_SHOWN = 12


# -- The loot tables ------------------------------------------------------------------------------

class Unsupported(Exception):
    pass


OPENERS = {"function", "if", "do", "repeat"}
CLOSERS = {"end", "until"}


class _Reader:
    """Reads one file's top-level assignments into `scope`, a dict of the globals so far: Lua
    tables become dicts, the array part keyed 1, 2, ... as Lua keys it."""

    def __init__(self, path, scope):
        with open(path, encoding="utf-8", errors="replace") as file:
            self.source = file.read()
        self.path = path
        self.tokens = luasource.tokenize(self.source)
        self.scope = scope

    def fail(self, at, what):
        line = self.source.count("\n", 0, self.tokens[min(at, len(self.tokens) - 1)].at) + 1
        raise Unsupported(f"{self.path}:{line}: {what}; findloot reads only table literals and references")

    def is_op(self, i, text):
        return i < len(self.tokens) and self.tokens[i].kind == OP and self.tokens[i].text == text

    def read(self):
        tokens, i, blocks, nesting = self.tokens, 0, 0, 0
        while i < len(tokens):
            token = tokens[i]
            if blocks == 0 and nesting == 0 and token.kind in (NAME, KEYWORD):
                target, j = self.target(i)
                if target and self.is_op(j, "="):
                    value, i = self.value(j + 1)
                    self.assign(target, value)
                    continue
            if token.kind == KEYWORD and token.text in OPENERS:
                blocks += 1
            elif token.kind == KEYWORD and token.text in CLOSERS:
                blocks -= 1
            elif token.kind == OP and token.text in "({[":
                nesting += 1
            elif token.kind == OP and token.text in ")}]":
                nesting -= 1
            i += 1

    def target(self, i):
        """The dotted name an assignment at token i sets (`local` dropped), and the token after it."""
        tokens = self.tokens
        if tokens[i].kind == KEYWORD:
            if tokens[i].text != "local" or i + 1 >= len(tokens) or tokens[i + 1].kind != NAME:
                return None, i
            i += 1
        if tokens[i].kind != NAME:
            return None, i
        path = [tokens[i].text]
        i += 1
        while self.is_op(i, ".") and i + 1 < len(tokens) and tokens[i + 1].kind == NAME:
            path.append(tokens[i + 1].text)
            i += 2
        return path, i

    def assign(self, path, value):
        table = self.scope
        for name in path[:-1]:
            table = table.get(name)
            if not isinstance(table, dict):
                return
        if value is None:
            table.pop(path[-1], None)
        else:
            table[path[-1]] = value

    def resolve(self, path):
        value = self.scope
        for name in path:
            value = value.get(name) if isinstance(value, dict) else None
        return value

    def value(self, i):
        """The value of the expression at token i, and the token after it: a literal, a table, a
        reference (nil when it names nothing, as in Lua), or `a or b` of those."""
        value, i = self.primary(i)
        while i < len(self.tokens) and self.tokens[i].kind == KEYWORD and self.tokens[i].text == "or":
            other, i = self.primary(i + 1)
            value = other if value is None or value is False else value
        if i < len(self.tokens) and self.tokens[i].kind == OP and self.tokens[i].text not in ",;}])":
            self.fail(i, f"an expression goes on with {self.tokens[i].text!r}")
        return value, i

    def primary(self, i):
        tokens = self.tokens
        if i >= len(tokens):
            self.fail(i, "the file ends inside an assignment")
        token = tokens[i]
        if token.kind == STRING:
            return token.text, i + 1
        if token.kind == NUMBER:
            return _number(token.text), i + 1
        if token.kind == OP and token.text == "-" and i + 1 < len(tokens) and tokens[i + 1].kind == NUMBER:
            return -_number(tokens[i + 1].text), i + 2
        if token.kind == KEYWORD and token.text in ("true", "false", "nil"):
            return {"true": True, "false": False, "nil": None}[token.text], i + 1
        if token.kind == OP and token.text == "{":
            return self.table(i + 1)
        if token.kind == NAME:
            path, i = self.target(i)
            if self.is_op(i, "(") or self.is_op(i, ":") or self.is_op(i, "["):
                self.fail(i, f"{'.'.join(path)} is called or indexed")
            return self.resolve(path), i
        self.fail(i, f"{token.text!r} starts an expression")

    def table(self, i):
        tokens, table, index = self.tokens, {}, 0
        while not self.is_op(i, "}"):
            if self.is_op(i, "["):
                key, i = self.value(i + 1)
                if not self.is_op(i, "]") or not self.is_op(i + 1, "="):
                    self.fail(i, "a [key] isn't followed by ] =")
                value, i = self.value(i + 2)
            elif i + 1 < len(tokens) and tokens[i].kind == NAME and self.is_op(i + 1, "="):
                key = tokens[i].text
                value, i = self.value(i + 2)
            else:
                index += 1
                key = index
                value, i = self.value(i)
            if value is not None:
                table[key] = value
            if self.is_op(i, ",") or self.is_op(i, ";"):
                i += 1
            elif not self.is_op(i, "}"):
                self.fail(i, "a table field isn't followed by , or }")
        return table, i + 1


def _number(text):
    if text.lower().startswith("0x"):
        return int(text, 16)
    number = float(text)
    return int(number) if number.is_integer() and "." not in text and "e" not in text.lower() else number


def _array(table):
    values, i = [], 1
    while i in table:
        values.append(table[i])
        i += 1
    return values


def _aliases(path):
    """The rooms mergeDistributions makes share another's table, alias -> room."""
    with open(path, encoding="utf-8", errors="replace") as file:
        tokens = luasource.tokenize(file.read())
    aliases = {}
    shape = [(NAME, "SuburbsDistributions"), (OP, "."), (NAME, None), (OP, "="),
             (NAME, "SuburbsDistributions"), (OP, "."), (NAME, None)]
    for i in range(len(tokens) - len(shape) + 1):
        window = tokens[i:i + len(shape)]
        if all(t.kind == kind and (text is None or t.text == text) for t, (kind, text) in zip(window, shape)):
            aliases[window[2].text] = window[6].text
    return aliases


class Loot:
    """The game's room and procedural loot tables, as the server's Lua leaves them."""

    def __init__(self, media):
        items = os.path.join(media, ITEMS)
        scope = {}
        # The game loads a folder's files in name order, which defines each table a later one
        # references (Distribution_*.lua's ClutterTables before Distributions.lua uses them).
        for name in ("Distribution_*.lua", "Distributions.lua", "ProceduralDistributions.lua"):
            for path in sorted(glob.glob(os.path.join(items, name))):
                _Reader(path, scope).read()
        self.lists = scope["ProceduralDistributions"]["list"]
        self.rooms = dict(scope["SuburbsDistributions"])
        for alias, room in _aliases(os.path.join(items, "SuburbsDistributions.lua")).items():
            if room in self.rooms:
                self.rooms[alias] = self.rooms[room]

    @staticmethod
    def weights(fill, pattern):
        """Matching item -> weight over a fill's items and its junk's, the chance each roll has."""
        found = collections.Counter()
        for part in (fill, fill.get("junk")):
            if not isinstance(part, dict) or not isinstance(part.get("items"), dict):
                continue
            entries = _array(part["items"])
            for item, weight in zip(entries[0::2], entries[1::2]):
                if isinstance(item, str) and isinstance(weight, (int, float)) and pattern.search(item):
                    found[item] += weight
        return found

    def containers(self):
        """(room, container, fill) for every container of every room, a room table being one with
        no rolls of its own (those are a bag's contents)."""
        for room, table in sorted(self.rooms.items()):
            if not isinstance(table, dict) or "rolls" in table:
                continue
            for container, fill in sorted(table.items(), key=lambda kv: str(kv[0])):
                if isinstance(fill, dict):
                    yield room, container, fill

    def find(self, pattern):
        """What can roll an item matching `pattern`: the items matched, then the procedural lists
        that hold them (name -> (weight, rolls, [(room, container, pick)])), and each room's ways to
        roll them (room -> [(container, list or None, weight, pick)], best first)."""
        matched = set()
        lists = {}
        for name, fill in self.lists.items():
            found = self.weights(fill, pattern) if isinstance(fill, dict) else {}
            if found:
                matched.update(found)
                lists[name] = (sum(found.values()), fill.get("rolls", 0), [])
        rooms = collections.defaultdict(list)
        for room, container, fill in self.containers():
            if fill.get("procedural"):
                entries = [entry for entry in _array(fill.get("procList", {})) if isinstance(entry, dict)]
                total = sum(entry.get("weightChance", 0) for entry in entries if not _forced(entry))
                for entry in entries:
                    if entry.get("name") in lists:
                        pick = _pick(entry, total)
                        lists[entry["name"]][2].append((room, container, pick))
                        rooms[room].append((container, entry["name"], lists[entry["name"]][0], pick))
            else:
                found = self.weights(fill, pattern)
                if found:
                    matched.update(found)
                    rooms[room].append((container, None, sum(found.values()), ""))
        for ways in rooms.values():
            ways.sort(key=lambda way: -way[2])
        return matched, lists, rooms


FORCES = ("forceForTiles", "forceForRooms", "forceForZones")


def _forced(entry):
    return [f"{key[len('forceFor'):].lower()} {entry[key]}" for key in FORCES if key in entry]


def _pick(entry, total):
    """How a container picks a procList entry: its weight against the unforced entries' total,
    or the tiles, rooms or zones it is forced for."""
    forced = _forced(entry)
    if forced:
        return "only for " + "; ".join(forced)
    return f"pick weight {_weight(entry['weightChance'])} of {_weight(total)}" if "weightChance" in entry else ""


# -- The map --------------------------------------------------------------------------------------

def read_rooms(media):
    """Every room of the vanilla map, as check/lotheader.py reads it: (name, floor, rects in world
    squares, building), building shared by the rooms of one building or None for a room in none."""
    rooms = []
    for path in glob.glob(os.path.join(media, MAP, "*.lotheader")):
        cx, cy = (int(part) for part in os.path.basename(path)[:-len(".lotheader")].split("_"))
        with open(path, "rb") as file:
            data = file.read()
        try:
            rooms += lotheader.parse(data, cx, cy)[3]
        except ValueError as error:
            raise Unsupported(str(error)) from None
    return rooms


def buildings(rooms, name):
    """Each building with a room called `name`: (x, y, floors), its centre over those rooms."""
    by_building = collections.defaultdict(list)
    for room in rooms:
        if room[0] == name:
            by_building[room[3] or id(room)].append(room)
    found = []
    for parts in by_building.values():
        rects = [rect for room in parts for rect in room[2]]
        x = (min(x for x, _, _, _ in rects) + max(x + w for x, _, w, _ in rects)) // 2
        y = (min(y for _, y, _, _ in rects) + max(y + h for _, y, _, h in rects)) // 2
        found.append((x, y, sorted({room[1] for room in parts})))
    return sorted(found)


class Places:
    """The world map's labels: towns, and the landmarks (places and buildings) it names."""

    def __init__(self, media):
        with open(os.path.join(media, MAP_LABELS), encoding="utf-8") as file:
            names = json.load(file)
        with open(os.path.join(media, MAP, "worldmap-annotations.lua"), encoding="utf-8") as file:
            tokens = luasource.tokenize(file.read())
        self.towns, self.landmarks = [], []
        for i, token in enumerate(tokens):
            if token.kind != NAME or token.text != "addUntranslatedText":
                continue
            text, style, x, y = (t.text for t in tokens[i + 2:i + 9:2])
            label = (re.sub(r"(?i)<br>", " ", names.get(text, text)), int(x), int(y))
            if style == "text-town":
                self.towns.append((label[0].title(), label[1], label[2]))
            elif style in ("text-place", "text-building"):
                self.landmarks.append(label)

    def describe(self, x, y):
        name, tx, ty = min(self.towns, key=lambda t: math.hypot(t[1] - x, t[2] - y))
        text = f"{name}, {round(math.hypot(tx - x, ty - y))} {_compass(x - tx, y - ty)}"
        landmark = min(self.landmarks, key=lambda t: math.hypot(t[1] - x, t[2] - y), default=None)
        if landmark and math.hypot(landmark[1] - x, landmark[2] - y) <= LANDMARK_SQUARES:
            text += f"; near {landmark[0]}"
        return text


def _compass(dx, dy):
    """The direction of (dx, dy) as N, NE, ..., the map's y growing southward."""
    if dx == 0 and dy == 0:
        return "at the label"
    angle = math.degrees(math.atan2(dx, -dy)) % 360
    return ("N", "NE", "E", "SE", "S", "SW", "W", "NW")[round(angle / 45) % 8]


# -- Output ---------------------------------------------------------------------------------------

def _floors(floors):
    return "z" + (str(floors[0]) if len(floors) == 1 else f"{floors[0]}..{floors[-1]}")


def _weight(weight):
    return f"{weight:g}"


def print_buildings(found, places, show_all, indent):
    shown = found if show_all else found[:BUILDINGS_SHOWN]
    for x, y, floors in shown:
        print(f"{indent}{x:>6}, {y:<6} {_floors(floors):<6} {places.describe(x, y)}")
    if len(found) > len(shown):
        print(f"{indent}... and {len(found) - len(shown)} more (--all lists them)")


def find_item(media, pattern, show_all):
    loot = Loot(media)
    matched, lists, rooms = loot.find(re.compile(pattern, re.I))
    if not matched:
        sys.exit(f"findloot: no loot table holds an item matching {pattern!r}")
    map_rooms = read_rooms(media)
    places = Places(media)
    print(f"Items: {', '.join(sorted(matched))}")
    print("\nProcedural lists that hold them (weight a roll, matches summed; rolls a fill):")
    for name, (weight, rolls, users) in sorted(lists.items(), key=lambda kv: (-kv[1][0], kv[0])):
        where = ", ".join(sorted({f"{room}.{container}" for room, container, _ in users})) or "no room picks it"
        print(f"  {name:<36} {_weight(weight):>6}  x{rolls:<3} {where}")
    print("\nRooms, best weight first; buildings at x, y, floor (z0 ground), nearest town:")
    for room, ways in sorted(rooms.items(), key=lambda kv: (-kv[1][0][2], kv[0])):
        print(f"\n  {room}")
        for container, list_name, weight, pick in ways:
            source = f"-> {list_name}" if list_name else "(own items)"
            print(f"    {container} {source} {_weight(weight)}{f' ({pick})' if pick else ''}")
        if room == "all":
            print("    (any room without a table of its own for the container)")
            continue
        found = buildings(map_rooms, room)
        if found:
            print_buildings(found, places, show_all, "    ")
        else:
            print("    (no room of this name on the map)")


def find_room(media, room, show_all):
    found = buildings(read_rooms(media), room)
    if not found:
        sys.exit(f"findloot: no room called {room!r} on the map")
    print(f"{room}: {len(found)} buildings at x, y, floor (z0 ground), nearest town")
    print_buildings(found, Places(media), show_all, "  ")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--media", default=DEFAULT_MEDIA, help="the game's media folder (default: the installed game's)")
    parser.add_argument("--room", help="list the buildings with this room type instead")
    parser.add_argument("--all", action="store_true", help=f"list every building, not the first {BUILDINGS_SHOWN} a room")
    parser.add_argument("item", nargs="?", help="a regular expression, case-insensitive, matched in item names")
    args = parser.parse_args()
    if bool(args.room) == bool(args.item):
        parser.error("give either an item pattern or --room")
    if not os.path.isdir(os.path.join(args.media, ITEMS)):
        sys.exit(f"findloot: {args.media} has no {ITEMS}; --media takes the game's media folder")
    # Piped into head, the output just stops, as a shell tool's does.
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    try:
        if args.room:
            find_room(args.media, args.room, args.all)
        else:
            find_item(args.media, args.item, args.all)
    except Unsupported as error:
        sys.exit(f"findloot: {error}")


if __name__ == "__main__":
    main()
