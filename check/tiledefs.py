"""Reads and writes tile definition files (.tiles), the tile properties a mod names in mod.info's
tiledef= line.

    python3 dev/harness/check/tiledefs.py FILE [TILE|all]

prints the file's tilesets, checks that writing them back gives the same bytes, and with a tile
index (or all) lists that tile's properties.

The layout follows IsoWorld.LoadTileDefinitions, which is the only reader that matters:

    "tdef", int32 version (1), int32 tileset count
    each tileset:
        line name, line image, int32 columns, int32 rows, int32 tileset number, int32 tile count
        each tile, in index order: int32 property count, then a line name and a line value each

Integers are little endian. A line is the bytes up to a newline, each byte read as one char, so
only Latin-1 survives the trip; a carriage return makes the loader throw. It trims names and
values, but not the image. The tileset number places the tileset's sprite IDs within the file
(IsoWorld.getSpriteID), so it has to be unique and from 1; a mod's file holds at most 512
tilesets of 512 tiles. Columns, rows and the image are TileZed's and the game ignores them.
"""
import struct
import sys
from dataclasses import dataclass, field

MAGIC = b"tdef"
VERSION = 1
# Limits for a file loaded with any file number but 1, which is the base game's own.
MAX_TILESETS = 512
MAX_TILES = 512

_INT = struct.Struct("<i")


@dataclass
class Tileset:
    name: str
    image: str
    columns: int
    rows: int
    number: int
    # Per tile index, its (property, value) pairs in file order. Most values are empty: the
    # property's presence is the flag.
    tiles: list = field(default_factory=list)


class _Cursor:
    def __init__(self, data):
        self.data = data
        self.at = 0

    def int(self):
        if self.at + 4 > len(self.data):
            raise ValueError("file ends inside an integer at byte %d" % self.at)
        (value,) = _INT.unpack_from(self.data, self.at)
        self.at += 4
        return value

    def line(self):
        end = self.data.find(b"\n", self.at)
        if end < 0:
            raise ValueError("unterminated string at byte %d" % self.at)
        raw = self.data[self.at:end]
        if b"\r" in raw:
            raise ValueError("carriage return at byte %d, which the game refuses" % self.at)
        self.at = end + 1
        return raw.decode("latin-1")

    def count(self, what, limit=None):
        value = self.int()
        if value < 0 or (limit is not None and value > limit):
            raise ValueError("%s %d at byte %d is outside 0..%s" % (what, value, self.at - 4, limit))
        return value


def loads(data, file_number=None):
    """The tilesets in a .tiles file's bytes. Raises ValueError where the game would fail.
    file_number 1 is the base game's main file, which may hold twice a mod file's tilesets."""
    limit = 2 * MAX_TILESETS if file_number == 1 else MAX_TILESETS
    if data[:4] != MAGIC:
        raise ValueError("does not start with %r" % MAGIC)
    cursor = _Cursor(data)
    cursor.at = 4
    version = cursor.int()
    if version != VERSION:
        raise ValueError("version %d, the game reads only %d" % (version, VERSION))
    tilesets = []
    for _ in range(cursor.count("tileset count", limit)):
        tileset = Tileset(cursor.line(), cursor.line(), cursor.int(), cursor.int(), cursor.int())
        if not 1 <= tileset.number <= limit:
            raise ValueError("%s has tileset number %d" % (tileset.name, tileset.number))
        for _ in range(cursor.count("tile count", 2 * MAX_TILES if file_number == 1 else MAX_TILES)):
            tileset.tiles.append([(cursor.line(), cursor.line())
                                  for _ in range(cursor.count("property count"))])
        tilesets.append(tileset)
    if cursor.at != len(data):
        raise ValueError("%d bytes left over after the last tileset" % (len(data) - cursor.at))
    return tilesets


def _line(text):
    if "\n" in text or "\r" in text:
        raise ValueError("line break in %r" % text)
    return text.encode("latin-1") + b"\n"


def dumps(tilesets):
    """A .tiles file's bytes. Refuses anything loads would refuse, so a bad file never ships."""
    if len(tilesets) > MAX_TILESETS:
        raise ValueError("%d tilesets, a mod file holds %d" % (len(tilesets), MAX_TILESETS))
    numbers = [tileset.number for tileset in tilesets]
    if len(set(numbers)) != len(numbers) or not all(1 <= n <= MAX_TILESETS for n in numbers):
        raise ValueError("tileset numbers must be unique and from 1 to %d: %s" % (MAX_TILESETS, numbers))
    out = [MAGIC, _INT.pack(VERSION), _INT.pack(len(tilesets))]
    for tileset in tilesets:
        if len(tileset.tiles) > MAX_TILES:
            raise ValueError("%s has %d tiles, the limit is %d" % (tileset.name, len(tileset.tiles), MAX_TILES))
        out += [_line(tileset.name), _line(tileset.image),
                struct.pack("<4i", tileset.columns, tileset.rows, tileset.number, len(tileset.tiles))]
        for properties in tileset.tiles:
            out.append(_INT.pack(len(properties)))
            for name, value in properties:
                out += [_line(name), _line(value)]
    return b"".join(out)


def load(path, file_number=None):
    with open(path, "rb") as f:
        return loads(f.read(), file_number)


def main(args):
    if not 1 <= len(args) <= 2:
        raise SystemExit(__doc__.split("\n\n")[1])
    with open(args[0], "rb") as f:
        data = f.read()
    tilesets = loads(data)
    for tileset in tilesets:
        used = sum(1 for properties in tileset.tiles if properties)
        print("%s: tileset %d, image %s %dx%d, %d tiles, %d with properties"
              % (tileset.name, tileset.number, tileset.image, tileset.columns, tileset.rows,
                 len(tileset.tiles), used))
        for index, properties in enumerate(tileset.tiles):
            if properties and len(args) == 2 and args[1] in ("all", str(index)):
                print("  %s_%d" % (tileset.name, index))
                for name, value in properties:
                    print("    %s%s" % (name, " = " + value if value else ""))
    if dumps(tilesets) != data:
        raise SystemExit("round trip: writing the tilesets back gives different bytes")
    print("round trip: identical")


if __name__ == "__main__":
    main(sys.argv[1:])
