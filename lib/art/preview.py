"""Helpers for a mod's review sheets, which its art/models/preview.py lays out from the files
make.sh wrote: compositing and enlarging pixel arrays (kit.load_pixels's), the floor a tile stands
on, an index.html gallery naming each piece, and the game's own sprites to hold the mod's against.
PZ_APP overrides the game's Contents folder, as in the harness's scripts.
"""
import html
import os

import numpy as np
from packs import read_index

from . import kit
from .render import TILE_H, TILE_W

GAME = os.environ.get("PZ_APP", os.path.expanduser(
    "~/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app/Contents"))
BACKGROUND = np.array([0.3, 0.3, 0.3, 1.0], dtype=np.float32)


def over(sheet, pixels, x, y):
    """Alpha-composites `pixels` onto `sheet` with its top left at (x, y)."""
    height, width, _ = pixels.shape
    region = sheet[y:y + height, x:x + width]
    alpha = pixels[..., 3:4]
    region[..., :3] = pixels[..., :3] * alpha + region[..., :3] * (1 - alpha)
    region[..., 3:] = alpha + region[..., 3:] * (1 - alpha)


def grid(cells, columns, cell_w, cell_h):
    rows = (len(cells) + columns - 1) // columns
    sheet = np.tile(BACKGROUND, (rows * cell_h, columns * cell_w, 1))
    for i, pixels in enumerate(cells):
        over(sheet, pixels, (i % columns) * cell_w, (i // columns) * cell_h)
    return sheet


def enlarge(pixels, factor):
    return pixels.repeat(factor, axis=0).repeat(factor, axis=1)


def floor_diamond(fill=None):
    """A tile's floor in its cell: its outline, or filled with `fill`, so a sprite's placement on its
    square shows."""
    width, height = TILE_W, TILE_H
    cell = np.zeros((height, width, 4), dtype=np.float32)
    for x in range(width):
        dy = round(abs(x - width / 2 + 0.5) / 2)
        top, bottom = height - width // 2 + dy, height - 1 - dy
        if fill is not None:
            cell[top:bottom + 1, x] = fill
        else:
            for y in (top, bottom):
                cell[min(y, height - 1), x] = (0.5, 0.5, 0.5, 1)
    return cell


def layer_caption(layer):
    """What a render.layer draws: its build's name, its options, and how it's turned and placed."""
    build = layer["build"]
    words = [getattr(build, "func", build).__name__]
    words += ["%s=%s" % item for item in sorted({**getattr(build, "keywords", {}), **layer["options"]}.items())]
    if layer["turn"]:
        words.append("turn %s" % layer["turn"])
    if layer["holdout"]:
        words.append("(overlay)")
    return " ".join(words)


class Gallery:
    """index.html in `out`: a page to review the art by, each piece on its own and named, in
    sections by `widths`, the width each section's images show at (a click opens one whole)."""

    def __init__(self, out, widths):
        self.out = out
        self.sections = {section: (width, []) for section, width in widths.items()}

    def add(self, section, file, caption):
        """Lists `file`, under `out`, in `section`."""
        self.sections[section][1].append((file, caption))

    def keep(self, section, folder, name, pixels, caption):
        """Saves `pixels` as out/folder/name.png and lists it in `section`."""
        file = "%s/%s.png" % (folder, name)
        kit.save_pixels(os.path.join(self.out, file), pixels)
        self.add(section, file, caption)

    def write(self, title):
        parts = ["<!doctype html><meta charset=utf-8><title>%s</title><style>" % html.escape(title),
                 "body{background:#2b2b2b;color:#ddd;font:13px system-ui;margin:16px}a{color:#9cf}"
                 "h2{margin:24px 0 8px}div{display:flex;flex-wrap:wrap;gap:8px}"
                 "figure{margin:0;background:#4d4d4d;padding:4px}"
                 "img{display:block;image-rendering:pixelated}figcaption{padding-top:4px;word-break:break-word}",
                 "</style><h1>%s</h1><p>" % html.escape(title),
                 " · ".join('<a href="#%d">%s (%d)</a>' % (i, section, len(entries))
                            for i, (section, (_, entries)) in enumerate(self.sections.items())),
                 "</p>"]
        for i, (section, (width, entries)) in enumerate(self.sections.items()):
            parts.append('<h2 id="%d">%s (%d)</h2><div>' % (i, section, len(entries)))
            for file, caption in entries:
                parts.append('<figure style="width:%dpx"><a href="%s"><img src="%s" width=%d loading=lazy></a>'
                             '<figcaption>%s</figcaption></figure>' % (width, file, file, width, html.escape(caption)))
            parts.append("</div>")
        with open(os.path.join(self.out, "index.html"), "w") as page:
            page.write("".join(parts))


def vanilla_sprite(name, scratch):
    """A sprite of the game's Tiles2x.pack as its full cell, or None without the game. Its page is
    written to the folder `scratch` to be read."""
    path = os.path.join(GAME, "Java", "media", "texturepacks", "Tiles2x.pack")
    if not os.path.exists(path):
        return None
    for page in read_index(path):
        for sprite in page.sprites:
            if sprite.name != name:
                continue
            with open(path, "rb") as f:
                f.seek(page.image_start)
                data = f.read(page.image_length)
            os.makedirs(scratch, exist_ok=True)
            page_file = os.path.join(scratch, "vanilla_page.png")
            with open(page_file, "wb") as f:
                f.write(data)
            pixels = kit.load_pixels(page_file)
            cell = np.zeros((sprite.cell_height, sprite.cell_width, 4), dtype=np.float32)
            cell[sprite.offset_y:sprite.offset_y + sprite.height, sprite.offset_x:sprite.offset_x + sprite.width] = \
                pixels[sprite.y:sprite.y + sprite.height, sprite.x:sprite.x + sprite.width]
            return cell
    return None
