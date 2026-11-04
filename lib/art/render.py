"""Renders a mod's tile sprites, their depth maps, its inventory icons and its build-menu icons, as
an Art says. A mod's art/models/render.py makes its Art and runs main:

    blender -b --factory-startup --python-use-system-env -P art/models/render.py [-- tiles [INDEX ...]|icons ...]

Tiles go to Art.tile_dir as whole TILE_W x TILE_H cells named <tileset>_<index>.png, for
pack.py to trim and pack, and each tileset's depth map to the mod's media/depthmaps. Item icons
go to Art.icon_dir as <icon_prefix><Item>.png, ICON_SIZE square like the game's own, and
build-menu icons as <build_icon_prefix><Name>.png, BUILD_ICON_SIZE square like the game's Build_
icons in UI2.pack. Tile numbers after `tiles` render only those, in every tileset that has any of
them, over the files already written, for working on a few.

The projection is the game's (TileDepthTexture, TileGeometryUtils): an orthographic camera 30
degrees above the horizon looking north-west, a tile floor 128 x 64 pixels, so 64 * sqrt(2)
pixels to the metre across the floor, and a storey of 2.44949 metres drawn 192 pixels tall. A
tile's floor centre is at pixel (64, 224) of its cell.

A render saves the date and Cycles' timings into its PNG, so the sprites and icons are saved from
the rendered pixels, and a rerun from unchanged sources writes the same bytes.
"""
import math
import os
import sys
from dataclasses import dataclass

import bpy
import numpy as np
from mathutils import Vector

from . import kit, shading
from .tilefile import COLUMNS

TILE_W, TILE_H = 128, 256
PIXELS_PER_METRE = 64 * math.sqrt(2)
STOREY = 2.44949
ICON_SIZE = 32
BUILD_ICON_SIZE = 48
ICON_OVERSAMPLE = 8  # rendered larger, then averaged down, so edges stay clean
ICON_DITHER = 0.03  # each icon pixel's brightness jitter, either way (pixel_icon)


@dataclass
class Art:
    """What a mod renders and where it goes. `tilesets` maps each tileset's name to its tiles, a
    list of layers by tile number; `items` maps an item's name to its spec: "model", the builder of
    its icon, or "icon" when the icon shows something else, "icon_elevation", the camera's degrees
    above the horizon (30, as a tile's, when absent), and "icon_turn", degrees the model is turned
    about the vertical. `build_icons` maps a build-menu icon's name to its layers. `scratch` is a
    folder of the mod's own for the raw renders."""
    media: str
    tile_dir: str
    icon_dir: str
    scratch: str
    tilesets: dict
    items: dict
    build_icons: dict
    icon_prefix: str
    build_icon_prefix: str

    def tile_file(self, tileset, index):
        return os.path.join(self.tile_dir, "%s_%d.png" % (tileset, index))

    def depth_file(self, tileset):
        # Where the game looks for a tileset's depth map (TileDepthTextureManager).
        return os.path.join(self.media, "depthmaps", "DEPTH_%s.png" % tileset)

    def icon_file(self, name):
        return os.path.join(self.icon_dir, self.icon_prefix + name + ".png")

    def build_icon_file(self, name):
        return os.path.join(self.icon_dir, self.build_icon_prefix + name + ".png")


def layer(build, holdout=False, at=(0, 0, 0), turn=0, scale=1, **options):
    """One builder's part of a tile or icon: `build(collection, **options)`'s parts placed at `at`,
    turned `turn` degrees about the vertical and scaled by `scale`. A `holdout` layer is drawn
    invisible: an overlay tile renders the object it sits on that way, so it keeps only the pixels
    the object doesn't hide."""
    return {"build": build, "options": options, "at": at, "turn": turn, "scale": scale, "holdout": holdout}


def view_direction(elevation=30.0):
    """From the camera into the scene: from the south-east, `elevation` degrees down."""
    e = math.radians(elevation)
    return Vector((-math.cos(e) / math.sqrt(2), math.cos(e) / math.sqrt(2), -math.sin(e)))


# Scene --------------------------------------------------------------------------------------------


def setup():
    stage = kit.new_stage(96, (0.55, 0.56, 0.6, 1))
    scene = bpy.context.scene
    scene.cycles.use_denoising = False
    scene.cycles.pixel_filter_type = "BLACKMAN_HARRIS"
    scene.cycles.filter_width = 1.2
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.resolution_percentage = 100
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    # The game's own tiles are lit from the upper left of the screen: west, a little south. A sun
    # shines down its -Z axis, so that is the axis turned along the light's way.
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.data.energy = 3.2
    sun.data.angle = math.radians(8)
    sun.rotation_euler = Vector((0.85, 0.35, -1.0)).to_track_quat("-Z", "Y").to_euler()
    scene.collection.objects.link(sun)
    camera = bpy.data.objects.new("Camera", bpy.data.cameras.new("Camera"))
    camera.data.type = "ORTHO"
    camera.data.sensor_fit = "HORIZONTAL"
    camera.data.clip_start, camera.data.clip_end = 0.1, 60
    scene.collection.objects.link(camera)
    scene.camera = camera
    return camera, stage


def build(stage, layers):
    for spec in layers:
        new = kit.added(stage, spec["build"], **spec["options"])
        placed = kit.group(stage, "Layer", [obj for obj in new if obj.parent is None], at=spec["at"], rotate=(0, 0, spec["turn"]))
        placed.scale = (spec["scale"],) * 3
        if spec["holdout"]:
            for obj in new:
                if obj.type == "MESH":
                    for i in range(len(obj.data.materials)):
                        obj.data.materials[i] = shading.holdout()
    bpy.context.view_layer.update()


def aim(camera, direction, centre, width):
    """Points the camera along `direction` with `centre` in the middle of a picture `width` metres
    across."""
    camera.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    camera.location = centre - direction * 20
    camera.data.ortho_scale = width
    bpy.context.view_layer.update()


def render(path, width, height):
    scene = bpy.context.scene
    scene.render.resolution_x, scene.render.resolution_y = width, height
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


# Tiles --------------------------------------------------------------------------------------------


def tile_camera(camera):
    direction = view_direction()
    up = direction.to_track_quat("-Z", "Y") @ Vector((0, 1, 0))
    # The picture's centre stands above the floor centre, as on the game's own tiles.
    aim(camera, direction, up * ((TILE_H / 2 - 32) / PIXELS_PER_METRE), TILE_W / PIXELS_PER_METRE)


def depth_of(point):
    """The game's tile depth at a point of the tile: 1 at the north-west floor corner, falling a
    quarter per metre east or south and a half per storey up (TileGeometryUtils.getNormalizedDepth)."""
    east = point.x + 0.5
    south = 0.5 - point.y
    return 1 - (east + south) / 4 - point.z / STOREY / 2


def depth_map(camera, alpha):
    """Casts a ray through every pixel the sprite covers and returns that pixel's depth. Pixels
    the sprite only partly covers, at its edges, may miss: they take a neighbour's depth, because
    the game discards every sprite pixel whose depth pixel is empty (tileWithDepth.frag)."""
    scene = bpy.context.scene
    depsgraph = bpy.context.evaluated_depsgraph_get()
    direction = view_direction()
    rotation = direction.to_track_quat("-Z", "Y")
    right, up = rotation @ Vector((1, 0, 0)), rotation @ Vector((0, 1, 0))
    depth = np.full(alpha.shape, -1.0, dtype=np.float32)
    for y, x in zip(*np.nonzero(alpha > 0)):
        origin = (camera.location + right * ((x + 0.5 - TILE_W / 2) / PIXELS_PER_METRE)
                  + up * ((TILE_H / 2 - y - 0.5) / PIXELS_PER_METRE))
        hit, location, *_ = scene.ray_cast(depsgraph, origin, direction)
        if hit:
            depth[y, x] = depth_of(location)
    while True:
        missing = (alpha > 0) & (depth < 0)
        if not missing.any():
            break
        padded = np.pad(depth, 1, constant_values=-1)
        neighbours = np.stack([padded[1 + dy:1 + dy + depth.shape[0], 1 + dx:1 + dx + depth.shape[1]]
                               for dy in (-1, 0, 1) for dx in (-1, 0, 1)])
        best = neighbours.max(axis=0)
        fill = missing & (best >= 0)
        if not fill.any():
            break
        depth[fill] = best[fill]
    return depth


def render_tiles(art, camera, stage, only=None):
    """Every tile of every tileset, or with `only` those tile numbers, over the sprites and depth
    maps already written."""
    os.makedirs(art.tile_dir, exist_ok=True)
    if not only:
        for stale in os.listdir(art.tile_dir):
            if stale.endswith(".png"):
                os.remove(os.path.join(art.tile_dir, stale))
    tile_camera(camera)
    for tileset, tileset_tiles in art.tilesets.items():
        if only and not only & set(tileset_tiles):
            continue
        depth_file = art.depth_file(tileset)
        rows = max(tileset_tiles) // COLUMNS + 1
        atlas = np.zeros((rows * TILE_H, COLUMNS * TILE_W, 4), dtype=np.float32)
        if only:
            # Every other tile keeps its depth from the map already written; a map written without
            # them would leave them drawing nothing in game.
            if not os.path.exists(depth_file):
                raise SystemExit("%s is missing: render every tile before rendering a few" % depth_file)
            written = kit.load_pixels(depth_file)
            # Fewer rows than the atlas when tiles were added since.
            atlas[:written.shape[0]] = written[:atlas.shape[0]]
        for index, layers in sorted(tileset_tiles.items()):
            if only and index not in only:
                continue
            kit.clear(stage)
            build(stage, layers)
            raw = os.path.join(art.scratch, "tile.png")
            render(raw, TILE_W, TILE_H)
            pixels = kit.load_pixels(raw)
            kit.save_pixels(art.tile_file(tileset, index), pixels)
            depth = depth_map(camera, pixels[..., 3])
            cell = atlas[index // COLUMNS * TILE_H:(index // COLUMNS + 1) * TILE_H,
                         index % COLUMNS * TILE_W:(index % COLUMNS + 1) * TILE_W]
            cell[...] = 0
            covered = depth >= 0
            cell[covered, :3] = np.maximum(depth[covered], 1 / 255)[:, None]
            cell[covered, 3] = 1
            print("tile %s_%d: %d layers, %d pixels" % (tileset, index, len(layers), int(covered.sum())))
        kit.save_pixels(depth_file, atlas)


# Icons --------------------------------------------------------------------------------------------


def icon_camera(camera, stage, elevation, icon_size):
    direction = view_direction(elevation)
    rotation = direction.to_track_quat("-Z", "Y")
    right, up = rotation @ Vector((1, 0, 0)), rotation @ Vector((0, 1, 0))
    points = [obj.matrix_world @ v.co for obj in stage.objects if obj.type == "MESH" for v in obj.data.vertices]
    across = [p.dot(right) for p in points]
    along = [p.dot(up) for p in points]
    size = max(max(across) - min(across), max(along) - min(along))
    centre = right * (max(across) + min(across)) / 2 + up * (max(along) + min(along)) / 2
    aim(camera, direction, centre, size * icon_size / (icon_size - 3))


def pixel_icon(pixels, size):
    """Averages a large render down to `size` and draws the game's dark outline: vanilla icons
    are pixel art with a solid silhouette whose edge pixels are a near-black shade of the object."""
    factor = pixels.shape[0] // size
    alpha = pixels[..., 3:4]
    blocks = (pixels[..., :3] * alpha).reshape(size, factor, size, factor, 3).mean(axis=(1, 3))
    coverage = alpha.reshape(size, factor, size, factor).mean(axis=(1, 3))
    colour = blocks / np.maximum(coverage, 1e-4)[..., None]
    # A little more contrast about mid-grey: averaging blurs the shading inside a silhouette,
    # and vanilla's hand-drawn icons spread their brightness wider than a downsampled render.
    colour = np.clip((colour - 0.5) * 1.15 + 0.5, 0, 1)
    # Vanilla's icons are drawn pixel by pixel and never quite flat; a fixed ±3% brightness jitter
    # by position gives a render the same grain, the same on every run.
    y, x = np.mgrid[0:size, 0:size].astype(np.uint32)
    jitter = ((x * np.uint32(73856093)) ^ (y * np.uint32(19349663))) % np.uint32(1021) / 1020.0 * 2 - 1
    colour = np.clip(colour * (1 + ICON_DITHER * jitter[..., None]), 0, 1)
    solid = coverage > 0.35
    padded = np.pad(solid, 1, constant_values=False)
    edge = solid & ~(padded[:-2, 1:-1] & padded[2:, 1:-1] & padded[1:-1, :-2] & padded[1:-1, 2:])
    # Capped, so a pale object's edge is as dark as a dark one's, as vanilla's are.
    colour[edge] = np.minimum(colour[edge] * 0.28, 0.12)
    out = np.zeros((size, size, 4), dtype=np.float32)
    out[..., :3] = colour
    out[..., 3] = solid
    return out


def render_icon(art, camera, stage, layers, elevation, size, path):
    kit.clear(stage)
    build(stage, layers)
    icon_camera(camera, stage, elevation, size)
    raw = os.path.join(art.scratch, "icon.png")
    render(raw, size * ICON_OVERSAMPLE, size * ICON_OVERSAMPLE)
    kit.save_pixels(path, pixel_icon(kit.load_pixels(raw), size))


def render_icons(art, camera, stage):
    # Only this mod's icons: an item or build icon that's gone leaves none behind.
    os.makedirs(art.icon_dir, exist_ok=True)
    for stale in os.listdir(art.icon_dir):
        if stale.startswith((art.icon_prefix, art.build_icon_prefix)):
            os.remove(os.path.join(art.icon_dir, stale))
    for name, spec in art.items.items():
        render_icon(art, camera, stage, [layer(spec.get("icon", spec["model"]), turn=spec.get("icon_turn", 0))],
                    spec.get("icon_elevation", 30), ICON_SIZE, art.icon_file(name))
        print("icon %s" % name)
    for name, layers in art.build_icons.items():
        render_icon(art, camera, stage, layers, 30, BUILD_ICON_SIZE, art.build_icon_file(name))
        print("build icon %s" % name)


def main(art):
    jobs = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else ["tiles", "icons"]
    only = {int(job) for job in jobs if job.isdigit()}
    camera, stage = setup()
    os.makedirs(art.scratch, exist_ok=True)
    if "tiles" in jobs:
        render_tiles(art, camera, stage, only)
    if "icons" in jobs:
        render_icons(art, camera, stage)
