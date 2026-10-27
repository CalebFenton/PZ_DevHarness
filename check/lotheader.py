"""The game's .lotheader files, which IsoMetaGrid builds the map's rooms and buildings from. Not a
static check of its own: lib/census.py and a mod's check plugins import it.

The layout is IsoMetaGrid's loader: optional "LOTH", int32 version (0 or 1), a tile count and that
many newline-terminated tile names (version 0 then has one stray byte), width and height in
chunks, version 0's level count or version 1's min and max level, then the rooms: a name line, the
level, a rect count and x, y, w, h per rect (in the cell, though a rect can run past its edge into
the next cell), and a count of three-int objects. Last come the buildings, each a count and that
many room indexes. Integers are little endian.
"""
import struct

CELL = 256


def parse(data, cx, cy):
    """(tile names, lowest level, highest level, rooms) of cell cx, cy's lotheader `data`, each
    room (name, level, rects in world squares, building), building being (cx, cy, index), unique
    on the map, or None for a room in no building."""
    at = 4 if data[:4] == b"LOTH" else 0

    def ints(n):
        nonlocal at
        values = struct.unpack_from("<%di" % n, data, at)
        at += 4 * n
        return values

    def line():
        nonlocal at
        end = data.index(b"\n", at)
        text = data[at:end].decode("latin-1")
        at = end + 1
        return text

    (version,) = ints(1)
    if version not in (0, 1):
        raise ValueError("lotheader %d,%d has version %d" % (cx, cy, version))
    tiles = [line() for _ in range(ints(1)[0])]
    if version == 0:
        at += 1
        _w, _h, levels = ints(3)
        min_level, max_level = 0, levels - 1
    else:
        _w, _h, min_level, max_level = ints(4)
    rooms = []
    for _ in range(ints(1)[0]):
        name = line()
        level, count = ints(2)
        rects = [(x + cx * CELL, y + cy * CELL, w, h) for x, y, w, h in (ints(4) for _ in range(count))]
        # Not `at += 12 * ints(1)[0]`: that reads at before ints moves it past the count.
        (objects,) = ints(1)
        at += 12 * objects
        rooms.append([name, level, rects, None])
    for building in range(ints(1)[0]):
        for room in ints(ints(1)[0]):
            rooms[room][3] = (cx, cy, building)
    return tiles, min_level, max_level, [tuple(room) for room in rooms]
