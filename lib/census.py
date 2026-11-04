#!/usr/bin/env python3
"""Counts what a thorough player could search in each town of the Build 42 map, and in the whole
map: every room, every container tile by the room it stands in, and every vehicle stall by its
vehicle zone. Writes them to `--out` as a Lua table a mod's loot report can require and multiply by
each container's, room's and vehicle's expected finds.

    dev/harness/lib/census.py --out <file.lua> [--by <command>] [PZ media folder]

The media folder defaults to the installed game's, which PZ_APP moves as in the harness's scripts.
Rerun it after a game update changes the map. It reads the files IsoMetaGrid and IsoLot read:

- <map>/<cx>_<cy>.lotheader: the cell's tile names, its levels and its rooms (check/lotheader.py).
- <map>/world_<cx>_<cy>.lotpack: "LOTP", int32 version, int32 chunk count, then an int64 offset
  per 8 x 8 chunk (index x * 32 + y). Each chunk lists its squares level by level, x then y: an
  int32 count; -1 and a count of squares to skip; or an int32 the game skips (-1 in Build 42
  maps) and count - 1 tile indexes into the header's names. Rooms come from the rects.
- <map>/objects.lua: the map zones; a ParkingStall zone's name is its VehicleZoneDistribution.
- *.tiles: each tile's properties; a container tile has a "container" property naming its type.

Vehicle stalls are counted as IsoChunk.AddVehicles_OnZone lays them out, with the spacing across
and along a zone depending on which way it faces.
Traffic jam zones (trafficjam<n|s|e|w>, and the rtrafficjam ones each chunk rolls for) are laid
out by IsoChunk.AddVehicles_TrafficJam_*, closer together; their counts are the expected number
of cars' slots, whether or not a car takes each.
"""
import argparse
import functools
import multiprocessing
import os
import re
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "check"))
import lotheader  # noqa: E402
import tiledefs  # noqa: E402

PZ_APP = os.environ.get("PZ_APP", os.path.expanduser(
    "~/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app/Contents"))
DEFAULT_MEDIA = os.path.join(PZ_APP, "Java", "media")
MAP = "Muldraugh, KY"
CELL = lotheader.CELL
CHUNK = 8

# The vanilla towns' bounds, x1, y1, x2, y2 inclusive, drawn around each one's built-up area.
TOWNS = [
    ("Muldraugh", 10550, 9250, 11000, 10700),
    ("West Point", 10900, 6550, 12200, 7150),
    ("Riverside", 5650, 5100, 7000, 5600),
    ("Rosewood", 7950, 11380, 8400, 11960),
    ("March Ridge", 9800, 12590, 10510, 13140),
]
# The whole map, counted last as one more area; the countryside and the other towns are what it
# holds beyond TOWNS.
WHOLE_MAP = "Whole map"


def container_types(media):
    """Tile name -> container type, from the game's tile definitions. The game reads its own
    files as file 1, which may hold more tilesets than a mod's."""
    types = {}
    for name in sorted(os.listdir(media)):
        if name.endswith(".tiles"):
            for tileset in tiledefs.load(os.path.join(media, name), 1):
                for index, props in enumerate(tileset.tiles):
                    for key, value in props:
                        if key == "container":
                            types["%s_%d" % (tileset.name, index)] = value
    return types


@functools.lru_cache(maxsize=None)
def read_header(path, cell):
    """The cell's tile names, its lowest and highest level, and its rooms as (name, level, rects),
    with the rects in world squares."""
    with open(path, "rb") as f:
        tiles, min_level, max_level, rooms = lotheader.parse(f.read(), *cell)
    return tiles, min_level, max_level, [(name, level, rects) for name, level, rects, _building in rooms]


def chunk_squares(pack, index, levels):
    """Yields (lx, ly, z, tile indexes) of one chunk's non-empty squares."""
    (offset,) = struct.unpack_from("<q", pack, 12 + index * 8)
    at = offset
    skip = 0
    for z in range(levels[0], levels[1] + 1):
        for x in range(CHUNK):
            for y in range(CHUNK):
                if skip > 0:
                    skip -= 1
                    continue
                (count,) = struct.unpack_from("<i", pack, at)
                at += 4
                if count == -1:
                    (skip,) = struct.unpack_from("<i", pack, at)
                    at += 4
                    if skip > 0:
                        skip -= 1
                        continue
                # count ints follow: the room, then count - 1 tiles. A count of 0 or 1 reads nothing
                # more, as in IsoLot's loader, which the map files are written for.
                if count > 1:
                    tiles = struct.unpack_from("<%di" % (count - 1), pack, at + 4)
                    at += 4 * count
                    yield x, y, z, tiles


def town_cells(folder, town, margin=0):
    """(cx, cy, lotheader path) of each cell of the map under the town's bounds, and `margin`
    cells around them."""
    _name, x1, y1, x2, y2 = town
    for cx in range(x1 // CELL - margin, x2 // CELL + 1 + margin):
        for cy in range(y1 // CELL - margin, y2 // CELL + 1 + margin):
            header = os.path.join(folder, "%d_%d.lotheader" % (cx, cy))
            if os.path.exists(header):
                yield cx, cy, header


def room_names(folder, town):
    """(x, y, z) -> room name for the squares of the town's rooms, from the town's cells and
    their neighbours, whose rects can reach in."""
    _name, x1, y1, x2, y2 = town
    names = {}
    for cx, cy, header in town_cells(folder, town, margin=1):
        for name, level, rects in read_header(header, (cx, cy))[3]:
            for rx, ry, w, h in rects:
                for x in range(max(rx, x1), min(rx + w, x2 + 1)):
                    for y in range(max(ry, y1), min(ry + h, y2 + 1)):
                        names[x, y, level] = name
    return names


def count_containers(folder, types, town):
    _name, x1, y1, x2, y2 = town
    rooms = room_names(folder, town)
    containers = {}
    for cx, cy, header in town_cells(folder, town):
        tiles, min_level, max_level, _rooms = read_header(header, (cx, cy))
        with open(os.path.join(folder, "world_%d_%d.lotpack" % (cx, cy)), "rb") as f:
            pack = f.read()
        for chx in range(CELL // CHUNK):
            for chy in range(CELL // CHUNK):
                ox, oy = cx * CELL + chx * CHUNK, cy * CELL + chy * CHUNK
                if ox + CHUNK <= x1 or ox > x2 or oy + CHUNK <= y1 or oy > y2:
                    continue
                for lx, ly, z, indexes in chunk_squares(pack, chx * 32 + chy, (min_level, max_level)):
                    room_name = rooms.get((ox + lx, oy + ly, z))
                    if room_name is None:
                        continue
                    for index in indexes:
                        kind = types.get(tiles[index])
                        if kind:
                            by_type = containers.setdefault(room_name, {})
                            by_type[kind] = by_type.get(kind, 0) + 1
    return containers


def count_rooms(folder, town):
    """Room name -> how many rooms of that name start inside the town."""
    _name, x1, y1, x2, y2 = town
    counts = {}
    for cx, cy, header in town_cells(folder, town):
        for name, _level, rects in read_header(header, (cx, cy))[3]:
            if rects and x1 <= rects[0][0] <= x2 and y1 <= rects[0][1] <= y2:
                counts[name] = counts.get(name, 0) + 1
    return counts


ZONE = re.compile(r'\{ name = "([^"]*)", type = "ParkingStall", x = (\d+), y = (\d+), z = 0, '
                  r'width = (\d+), height = (\d+)(?:, properties = \{ Direction = "(\w)" \})?')


def stalls_along(start, length, step):
    count, at = 0, start + step / 2.0
    while at < start + length:
        count, at = count + 1, at + step
    return count


JAM = re.compile(r"^r?trafficjam([nsew])$")


def jam_slots_along(start, length, first, step, jitter):
    """Expected slots along one axis of a traffic jam zone, as each chunk lays them: from the
    first slot of the zone's grid (start + first + step * k) inside the chunk, then every `step`
    squares, or one less half the time when `jitter`, while still inside the chunk and the zone."""
    end, count = start + length, 0.0
    for chunk in range(start // CHUNK * CHUNK, end, CHUNK):
        at = start + first
        while at < chunk:
            at += step
        limit = min(chunk + CHUNK, end)
        if at >= limit:
            continue
        count += 1
        for next_at, chance in (((at + step - 1, 0.5), (at + step, 0.5)) if jitter else ((at + step, 1.0),)):
            if next_at < limit:
                count += chance
    return count


def jam_slots(facing, x, y, w, h):
    """Slots in a traffic jam zone, spaced as IsoChunk.AddVehicles_TrafficJam_* lays them: rows
    across the road, cars along it."""
    if facing in ("n", "s"):
        return jam_slots_along(x, w, 1, 3, False) * jam_slots_along(y, h, 3, 6, True)
    return jam_slots_along(y, h, 1, 3, False) * jam_slots_along(x, w, 3, 6, False)


def parking_zones(folder):
    """The map's ParkingStall zones as (name, x, y, w, h, direction)."""
    with open(os.path.join(folder, "objects.lua"), encoding="latin-1") as f:
        text = f.read()
    return [(m.group(1), *map(int, m.groups()[1:5]), m.group(6)) for m in ZONE.finditer(text)]


def vehicle_stalls(zones, town):
    _name, x1, y1, x2, y2 = town
    stalls = {}
    for name, x, y, w, h, direction in zones:
        if not (x1 <= x + w / 2 <= x2 and y1 <= y + h / 2 <= y2):
            continue
        key = (name or "parkingstall").lower()
        jam = JAM.match(key)
        if jam:
            count = jam_slots(jam.group(1), x, y, w, h)
        elif "trafficjam" in key:
            continue  # A misspelt jam, which the engine neither jams nor parks.
        else:
            # The engine's guess at the facing of a zone without a Direction (IsoChunk.AddVehicles_OnZone).
            facing = "N"
            if w in (4, 5, 6) and (h <= 3 or h >= 6):
                facing = "W"
            facing = direction or facing
            across, along = (3, 5) if facing in ("N", "S") else (5, 3)
            count = stalls_along(x, w, across) * stalls_along(y, h, along)
        stalls[key] = stalls.get(key, 0) + count
    return stalls


def lua_table(counts, indent):
    """One line per room's container map; scalar counts packed several to a line, as the file
    would otherwise run to thousands of lines."""
    pad = " " * indent
    lines, packed = [], ""
    for key in sorted(counts):
        value = counts[key]
        if isinstance(value, dict):
            lines.append('%s["%s"] = { %s },' % (pad, key, ", ".join('["%s"] = %d' % (k, value[k]) for k in sorted(value))))
            continue
        entry = '["%s"] = %g,' % (key, round(value, 1))
        if packed and len(pad) + len(packed) + 1 + len(entry) > 100:
            lines.append(pad + packed)
            packed = ""
        packed = packed + " " + entry if packed else entry
    if packed:
        lines.append(pad + packed)
    return "\n".join(lines)


def whole_map(folder):
    """The bounds of every cell the map has, as a town."""
    cells = [tuple(map(int, re.match(r"(\d+)_(\d+)\.lotheader$", name).groups()))
             for name in os.listdir(folder) if re.match(r"\d+_\d+\.lotheader$", name)]
    xs, ys = [cx for cx, _ in cells], [cy for _, cy in cells]
    return (WHOLE_MAP, min(xs) * CELL, min(ys) * CELL, (max(xs) + 1) * CELL - 1, (max(ys) + 1) * CELL - 1)


def cell_containers(job):
    """count_containers over one cell, for the whole map's pool."""
    folder, types, cx, cy = job
    return count_containers(folder, types, ("cell", cx * CELL, cy * CELL, (cx + 1) * CELL - 1, (cy + 1) * CELL - 1))


def count_containers_by_cell(folder, types, town):
    """count_containers over a large area a cell at a time, in parallel: one call over the whole
    map would hold every room square at once."""
    jobs = [(folder, types, cx, cy) for cx, cy, _ in town_cells(folder, town)]
    containers = {}
    with multiprocessing.Pool() as pool:
        for part in pool.imap_unordered(cell_containers, jobs, chunksize=16):
            for room_name, by_type in part.items():
                total = containers.setdefault(room_name, {})
                for kind, count in by_type.items():
                    total[kind] = total.get(kind, 0) + count
    return containers


def main():
    parser = argparse.ArgumentParser(description="Counts the rooms, containers and vehicle stalls of the map's towns.")
    parser.add_argument("media", nargs="?", default=DEFAULT_MEDIA, help="the game's media folder")
    parser.add_argument("--out", required=True, help="the Lua file to write")
    parser.add_argument("--by", default="dev/harness/lib/census.py", help="the command the file says wrote it")
    args = parser.parse_args()
    folder = os.path.join(args.media, "maps", MAP)
    types = container_types(args.media)
    zones = parking_zones(folder)
    out = ["-- Written by %s from the game's map; rerun it rather than edit this file." % args.by,
           "-- towns: each town's bounds, its rooms by name, its container tiles by room name and",
           "-- container type, and its vehicle stalls by vehicle zone; the last is the whole map.",
           "return {",
           "    towns = {"]
    for town in TOWNS + [whole_map(folder)]:
        name, x1, y1, x2, y2 = town
        print("counting", name, file=sys.stderr)
        count = count_containers_by_cell if name == WHOLE_MAP else count_containers
        out.append('        { name = "%s", x1 = %d, y1 = %d, x2 = %d, y2 = %d,' % (name, x1, y1, x2, y2))
        for field, counts in (("rooms", count_rooms(folder, town)),
                              ("containers", count(folder, types, town)),
                              ("vehicleStalls", vehicle_stalls(zones, town))):
            out.append("            %s = {" % field)
            out.append(lua_table(counts, 16))
            out.append("            },")
        out.append("        },")
    out.append("    },")
    out.append("}")
    with open(args.out, "w") as f:
        f.write("\n".join(out) + "\n")
    print("wrote", args.out, file=sys.stderr)


if __name__ == "__main__":
    main()
