#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow"]
# ///
"""Crops the screenshots of a capture mode (PZHarness/Capture.lua) into the named images of the
mod's captures directory, and saves the rest of what the run wrote, such as the names the game
reported, as promo.json there. run-client.sh runs it after a capture mode that sets
MODE_CAPTURES_<mode> (docs/adopting.md, "Capture modes"); by hand:

    dev/harness/lib/capture.py <cache dir> <mark> <captures dir>

A mod that makes more captures of its own imports this module and adds them before finish().

Only the captures of the groups the run shot are replaced; promo.json lists each group's captures,
so that a rerun of a group also removes the ones it no longer makes.

Each shot of something other than the world is taken twice, on black and on white: a pixel that
reads k on black and w on white has alpha a = 1 - (w - k) and colour k / a.
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image


def load(path):
    """An image as floats from 0 to 1, without alpha."""
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255


def matte(black, white):
    alpha = np.clip(1 - (white - black).mean(axis=2), 0, 1)[..., None]
    colour = np.clip(black / np.maximum(alpha, 1 / 255), 0, 1)
    return Image.fromarray(np.round(np.dstack([colour, alpha]) * 255).astype(np.uint8), "RGBA")


def pixel_box(region, scale):
    """A manifest region, in UI units, as a crop box in screenshot pixels."""
    return [round(v * scale) for v in (region["x"], region["y"], region["x"] + region["w"], region["y"] + region["h"])]


class Extraction:
    """A run's captures: on creation, removes the old captures of the groups it shot and saves its
    shots' regions; `manifest` then holds the rest of <mark>.json and `previous` the last
    promo.json, and finish() writes the new one."""

    def __init__(self, cache, mark, captures):
        cache = Path(cache)
        self.screenshots = cache / "Screenshots"
        self.captures = Path(captures)
        self.promo = self.captures / "promo.json"
        self.manifest = json.loads((cache / "Lua" / f"{mark}.json").read_text())
        self.previous = json.loads(self.promo.read_text()) if self.promo.exists() else {}
        self.saved = self.previous.get("captures", {})
        self.ran = self.manifest.pop("groups")
        for group in self.ran:
            for name in self.saved.pop(group, []):
                (self.captures / f"{name}.png").unlink(missing_ok=True)
            self.saved[group] = []
        self.captures.mkdir(parents=True, exist_ok=True)
        self.screen_w = self.manifest.pop("screen")["w"]
        for shot in self.manifest.pop("shots"):
            file = shot["file"]
            if shot["matte"]:
                image = matte(load(self.screenshots / f"{file}_k.png"), load(self.screenshots / f"{file}_w.png"))
            else:
                image = Image.open(self.screenshots / f"{file}.png").convert("RGB")
            for region in shot["regions"]:
                self.save(image.crop(pixel_box(region, self.scale(image))), shot["group"], region["name"])

    def scale(self, image):
        """Screenshot pixels per UI unit: they differ on a HiDPI display."""
        return image.width / self.screen_w

    def save(self, image, group, name):
        """Saves captures/<name>.png as one of `group`'s captures."""
        image.save(self.captures / f"{name}.png", optimize=True)
        self.saved[group].append(name)

    def finish(self):
        self.manifest["captures"] = {group: sorted(names) for group, names in sorted(self.saved.items())}
        self.promo.write_text(json.dumps(self.manifest, indent=2, ensure_ascii=False) + "\n")
        count = sum(len(self.saved[group]) for group in self.ran)
        print(f"extract: {count} images from {', '.join(self.ran)} and promo.json in {self.captures}")


if __name__ == "__main__":
    Extraction(*sys.argv[1:4]).finish()
