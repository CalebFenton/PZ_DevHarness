# The art library

How a mod that adds tiles and items builds their art with `lib/art`: the meshes and materials of
its Blender builders, the tile sprites, depth maps and icons rendered from them, the review sheets,
the FBX models, the `.tiles` file and the texture pack. The mod keeps what is its own: its
palette, builders, tile tables, the game's props it replicates, and its paths and names, which it
passes in. [adopting.md](adopting.md) covers the rest of what a mod gives the harness.

## References before drawing

Art is drawn from references, never from an idea of the thing alone. Before building or changing
an item, tile or model, gather these and keep them on its review sheet beside the render:

- **What it is in the game.** The recipe or job that makes it, its weight, and what uses it up.
  Draw only that. A prop it doesn't contain, such as a container for loose stuff, is wrong.
- **The game's own art.** The closest vanilla item, and the items and objects it goes with: what
  it is made from, what it is used in, and where it sits. A gas bag is checked against the
  digester it fits; a filter's packing against the hay it was made from and the gasifier that
  burns it. These set the style, the colours, the size of an icon in its cell and of a model on
  the floor. Measure a vanilla mesh for size rather than guessing it. `preview.vanilla_sprite`
  reads tiles; the texture packs' `Item_*` sprites are the icons.
- **Photographs.** A couple of real-world photos of the thing, for its shape, material and wear.

## Layout

A mod's scripts put `dev/harness/lib` on `sys.path` and import from the package:

```python
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [HERE, os.path.join(os.path.dirname(os.path.dirname(HERE)), "dev", "harness", "lib")]
from art import kit, render  # noqa: E402
```

| Module | Runs in | What it is |
| --- | --- | --- |
| `art/kit.py` | Blender | Mesh primitives in metres, +Z up, an item's front to -Y (`box`, `beam`, `board`, `cylinder`, `tube`, `ring`, `prism`, `loft`, `lathe`, `bank`, `mound`, `text`), placing and grouping (`place`, `group`, `added`, `parts`, `edited_copy`, `select`), directions (`FACING_TURN`, the camera's `LEFT`/`RIGHT`/`TOWARD`/`UP`, `heading`, `around`, `circle`, `spline`), and the stage and pixels (`new_stage`, `clear`, `load_pixels`, `save_pixels`). |
| `art/shading.py` | Blender | `material(name, colour, ...)`, a painted, plastic, metal or wooden surface with grime, speckle, streaks, scorch, grain, turf, fade and glow; `holdout()`; `stain(name, colour, ...)`, a floor patch that meets its neighbours' across tile edges. |
| `art/render.py` | Blender | The game's tile projection: tile sprites, their depth maps and the item and build-menu icons, as an `Art` says. |
| `art/preview.py` | Blender | Review sheet helpers (`over`, `grid`, `enlarge`, `floor_diamond`), an `index.html` `Gallery`, `layer_caption`, and `vanilla_sprite`, a sprite of the game's `Tiles2x.pack` to hold the mod's against. |
| `art/fbx.py` | Blender | `export(path, obj, *others, **options)`, FBX files that come out the same bytes from the same scene. |
| `art/tilefile.py` | Python 3.10 | `write(media, file_name, tilesets)`: the `.tiles` file and `tileGeometry.txt`; `facings`, the placing cursor's rotation properties; `COLUMNS`. |
| `art/pack.py` | Python 3.10, Pillow | `pack(pack_file, page_name, trimmed_dir, whole_dir)`: the texture pack of the tile sprites and icons. |
| `blender.sh` | bash | `blender [FILE.blend] SCRIPT`, for the mod's `art/models/make.sh`. |

`tilefile`, `pack` and `preview` read and write the formats of the static check's `check/tiledefs.py`
and `check/packs.py`; importing `art` puts `check` on `sys.path`.

## A mod's scripts

```sh
#!/usr/bin/env bash
# art/models/make.sh
set -euo pipefail
cd "$(dirname "$0")"
. ../../dev/harness/lib/blender.sh
blender render.py
python3 ../../tools/make_tiles.py
../../tools/pack_textures.py
blender preview.py
```

```python
# art/models/render.py
import items, tiles  # the mod's
from art import render

ART = render.Art(media=MEDIA, tile_dir=os.path.join(REPO, "tools/tiles"), icon_dir=os.path.join(REPO, "tools/textures"),
                 scratch=os.path.join(tempfile.gettempdir(), "my-mod-render"), tilesets={"my_mod_01": tiles.TILES},
                 items=items.ITEMS, build_icons=tiles.BUILD_ICONS, icon_prefix="Item_MyMod_",
                 build_icon_prefix="MyMod_Build_")

if __name__ == "__main__":
    render.main(ART)
```

- `Art.tilesets` maps each tileset's name to its tiles, `{number: layers}`; a tileset's depth map
  has as many rows of `COLUMNS` as its highest number needs. `Art.items` maps an item's name to its
  spec: `"model"`, the builder of its icon, or `"icon"` when the icon shows something else;
  `"icon_elevation"`, the camera's degrees above the horizon (30, a tile's, when absent); and
  `"icon_turn"`, degrees about the vertical. `Art.build_icons` maps a build-menu icon's name to its
  layers. The mod's preview reads the files back through `Art.tile_file`, `icon_file` and
  `build_icon_file`.
- An icon is rendered `ICON_OVERSAMPLE` times larger and averaged down (`pixel_icon`): a little
  more contrast about mid-grey, no change to saturation or brightness, a fixed ±`ICON_DITHER`
  brightness jitter by pixel position, and an outline as dark as vanilla's (the fill × 0.28, at
  most 0.12), so pale items keep their silhouette. A material's grime follows each part's own
  extent as well as its metres, so a small part gets blotches too. `kit.text(..., bold=metres)`
  thickens lettering whose strokes a small icon would lose.
- A layer is `render.layer(build, holdout=False, at=(0, 0, 0), turn=0, scale=1, **options)`:
  `build(collection, **options)`'s parts, placed, turned about the vertical and scaled. A `holdout`
  layer draws invisible, so an overlay tile drawn over its base keeps only what the base doesn't
  hide.
- `render.py -- tiles 129 130` renders only those tile numbers, in every tileset that has any,
  keeping the rest of each depth map already written; `-- icons` renders only the icons.
- `tools/make_tiles.py` calls `tilefile.write(MEDIA, "my_mod.tiles", [(tileset, rows, properties)])`,
  each tileset's properties `{number: {name: value}}`, the tilesets numbered from 1 in that order.
- `tools/pack_textures.py` is a `uv run --script` file that pins Pillow and calls
  `pack(PACK_FILE, PAGE_NAME, tools/tiles, tools/textures)`.
- A preview that reads the game's sprites finds the game where the harness's scripts do: `PZ_APP`
  overrides its Contents folder.

## The same bytes from the same sources

A rebuild from unchanged sources writes the same files, so git shows only what a change touched:

- A render saves the date and Cycles' timings into its PNG, so `render.py` saves the sprites and
  icons from the rendered pixels.
- Blender's FBX exporter names objects and orders animation curves by `hash()`, which Python salts
  per process unless `PYTHONHASHSEED` fixes it, and Blender reads it only with
  `--python-use-system-env`: `blender.sh` passes both, and importing `art.fbx` exits without them.
  The exporter also stamps the time of writing, which `art.fbx` fixes, and a texture's path, so a
  model exports with a material that has none, or with `path_mode="STRIP"`.
- Two builds of Pillow can compress the same pixels to different bytes, so `pack_textures.py` and
  any other Pillow script pin the version uv installs.
- `kit.clear` restarts the wood grain offsets, so a build's parts get the same grain whatever was
  built before it.
