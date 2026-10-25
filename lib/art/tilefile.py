"""Writes a mod's tile definitions (.tiles, in the static check's tiledefs.py format) and the
tileGeometry.txt that makes the game load its depth maps. A mod's tools/make_tiles.py holds its
tile properties and calls write.

Property names and values follow the vanilla tile definitions (newtiledefinitions.tiles);
ISMoveableSpriteProps reads the moveable ones.
"""
import os

import tiledefs

COLUMNS = 8  # the game reads tilesets and their depth maps eight tiles wide


def facings(tiles, facing):
    """The placing cursor's rotation for `facing`'s tile of `tiles`, a tile number by facing: Facing
    and the N/S/E/Woffset pointing from its number to the others' in the same tileset
    (ISMoveableSpriteProps.getFaces)."""
    own = tiles[facing]
    return {"Facing": facing, **{other + "offset": str(index - own) for other, index in tiles.items() if other != facing}}


def write(media, file_name, tilesets):
    """Writes media/file_name with `tilesets`, each (name, rows, properties by tile number), numbered
    from 1 in that order, and media/tileGeometry.txt. A tile's properties are sorted by name, the
    case ignored; the rows are the mod's, so a tileset keeps its size as tiles come and go."""
    written = []
    for number, (name, rows, properties) in enumerate(tilesets, 1):
        assert max(properties, default=0) < COLUMNS * rows, "%s has more tiles than rows" % name
        tiles = [sorted(properties.get(index, {}).items(), key=lambda prop: prop[0].lower())
                 for index in range(COLUMNS * rows)]
        written.append(tiledefs.Tileset(name, name + ".png", COLUMNS, rows, number, tiles))
    data = tiledefs.dumps(written)
    assert tiledefs.loads(data) == written, "the tiles would not read back as written"
    os.makedirs(media, exist_ok=True)
    with open(os.path.join(media, file_name), "wb") as f:
        f.write(data)
    print("%s: %d tiles with properties" % (file_name, sum(len(properties) for _, _, properties in tilesets)))
    # The game loads a mod's depth maps (media/depthmaps/DEPTH_<tileset>.png) only when its media
    # has a tileGeometry.txt (TileDepthTextureManager.init), so this writes one without geometry.
    # Without the depth map every tile would be drawn as if it filled its square up to the ceiling.
    with open(os.path.join(media, "tileGeometry.txt"), "w") as f:
        f.write("tileGeometry\n{\n    VERSION = 2,\n}\n")
