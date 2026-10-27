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

A run whose data has `models` shot each item alone on a plain floor, and the floor empty too (a
manifest entry per item: { name, group, file, floor, window }). Where the item's shot differs from
the empty floor is the item: it is cropped around it into <name>.png, and promo.json's `models`
gives the item's box in that crop (docs/workshop-page.md, "Item models").
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

# A pixel belongs to the item where a channel differs from the empty floor's by more than this.
ITEM_DIFFERENCE = 0.06
# Rows and columns with fewer item pixels than this are noise.
ITEM_MIN_PIXELS = 3
# A model capture reaches this share of the item's longer side past it on every side, for the
# layout to frame it, and keeps its longer side within MODEL_MAX pixels.
MODEL_MARGIN = 0.35
MODEL_MAX = 512


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


def item_box(shot, floor):
    """The box (left, top, right, bottom) around what differs between shot and floor, or None."""
    differs = np.abs(shot - floor).max(axis=2) > ITEM_DIFFERENCE
    rows = np.flatnonzero(differs.sum(axis=1) >= ITEM_MIN_PIXELS)
    columns = np.flatnonzero(differs.sum(axis=0) >= ITEM_MIN_PIXELS)
    if not len(rows) or not len(columns):
        return None
    return [int(columns[0]), int(rows[0]), int(columns[-1]) + 1, int(rows[-1]) + 1]


class Extraction:
    """A run's captures: on creation, removes the old captures of the groups it shot and saves its
    shots' regions and item models; `manifest` then holds the rest of <mark>.json and `previous`
    the last promo.json, and finish() writes the new one."""

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
        if "models" in self.manifest:
            floors = {}
            models = [self.model(entry, floors) for entry in self.manifest["models"]]
            # A run that shot no models keeps the boxes of the last one that did.
            self.manifest["models"] = models or self.previous.get("models", [])

    def scale(self, image):
        """Screenshot pixels per UI unit: they differ on a HiDPI display."""
        return image.width / self.screen_w

    def save(self, image, group, name):
        """Saves captures/<name>.png as one of `group`'s captures."""
        image.save(self.captures / f"{name}.png", optimize=True)
        self.saved[group].append(name)

    def model(self, entry, floors):
        """Saves an item's shot cropped around the item and returns its promo.json entry."""
        image = Image.open(self.screenshots / f"{entry['file']}.png").convert("RGB")
        window = pixel_box(entry["window"], self.scale(image))
        if entry["floor"] not in floors:
            floors[entry["floor"]] = load(self.screenshots / f"{entry['floor']}.png")
        image = image.crop(window)
        floor = floors[entry["floor"]][window[1]:window[3], window[0]:window[2]]
        box = item_box(np.asarray(image, dtype=np.float32) / 255, floor)
        if box is None:
            sys.exit(f"extract: no item in {entry['file']}.png")
        if box[0] <= 1 or box[1] <= 1 or box[2] >= image.width - 1 or box[3] >= image.height - 1:
            print(f"extract: {entry['name']} runs past the window of {entry['file']}.png")
        margin = round(max(box[2] - box[0], box[3] - box[1]) * MODEL_MARGIN)
        crop = [max(0, box[0] - margin), max(0, box[1] - margin),
                min(image.width, box[2] + margin), min(image.height, box[3] + margin)]
        image = image.crop(crop)
        box = [box[0] - crop[0], box[1] - crop[1], box[2] - crop[0], box[3] - crop[1]]
        factor = MODEL_MAX / max(image.size)
        if factor < 1:
            image = image.resize((round(image.width * factor), round(image.height * factor)), Image.LANCZOS)
            box = [round(v * factor) for v in box]
        self.save(image, entry["group"], entry["name"])
        return {"name": entry["name"], "box": box}

    def missing(self):
        """The captures promo.json's catalog names call for that no run has made: the icons of its
        items and recipes, and with `models` each item's model."""
        icons = {item["icon"] for item in self.manifest.get("items", [])}
        for recipe in self.manifest.get("recipes", []):
            for line in recipe["inputs"]:
                icons.update(item["icon"] for item in line["items"])
            icons.update(item["icon"] for item in recipe["outputs"])
            if recipe.get("build"):
                icons.add(recipe["build"]["icon"])
        names = sorted(icon for icon in icons if not (self.captures / f"{icon}.png").exists())
        if "models" in self.manifest:
            models = {model["name"] for model in self.manifest["models"]}
            names += [name for name in ("model_" + item["fullType"].replace(".", "_")
                                        for item in self.manifest.get("items", [])) if name not in models]
        return names

    def group_making(self, prefix):
        """The group that made the captures named `prefix`..., or None."""
        return next((group for group, names in sorted(self.saved.items())
                     if any(name.startswith(prefix) for name in names)), None)

    def finish(self):
        self.manifest["captures"] = {group: sorted(names) for group, names in sorted(self.saved.items())}
        self.promo.write_text(json.dumps(self.manifest, indent=2, ensure_ascii=False) + "\n")
        count = sum(len(self.saved[group]) for group in self.ran)
        print(f"extract: {count} images from {', '.join(self.ran)} and promo.json in {self.captures}")
        for name in self.missing():
            group = self.group_making(name.split("_", 1)[0] + "_")
            print(f"extract: no capture {name}.png" + (f"; reshoot the {group} group" if group else ""))


if __name__ == "__main__":
    Extraction(*sys.argv[1:4]).finish()
