"""Lays out a mod's Workshop pages from the captures of its capture mode: the README's images, the
gallery, the poster and Workshop preview, and the mod list's icon (docs/workshop-page.md, "Laying
out the images"). A mod's art/promo/compose.py, a `uv run --script` file that brings Pillow, puts
this folder on sys.path and imports it:

    sys.path.insert(0, str(REPO / "dev" / "harness" / "lib"))
    import promo

Every README image is WIDTH pixels wide, which the Workshop page shows at half that, so it stays
sharp on high-density screens. A layout is drawn at the README's size, or k times it for the
gallery's larger pages, where sized(n, k) is n of the README's pixels. Icons and interface
captures grow by whole numbers with nearest-neighbour sampling, so their pixels stay crisp.

Names come from the captures' promo.json, which the game wrote in its own words: `strings.modName`,
and `items` and `recipes` as PZHarness/Capture.lua's builders write them. Each item and recipe
names its icon's capture, `icon_<Module>_<Type>` or `icon_build_<name>`.
"""
import json
import math
import os
import re
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

FONT = Path(__file__).resolve().parent / "fonts" / "NotoSans.ttf"

WIDTH = 1260
BACKGROUND = (24, 26, 31)
PANEL = (36, 39, 46)
TEXT = (232, 234, 238)
MUTED = (160, 166, 176)

# The Workshop's gallery shows pictures at 16:9 and enlarges one to its own size; a file must stay
# under a megabyte (ISteamUGC::AddItemPreviewFile), half the upload page's limit.
GALLERY_SIZE = (1920, 1080)
GALLERY_BYTES = 1_000_000
# Every picture's caption sits centred in a band across its top, the same on every mod's gallery;
# PAGE is what's left below it.
CAPTION_BAND = 150
CAPTION_SIZE = 60
PAGE = (GALLERY_SIZE[0], GALLERY_SIZE[1] - CAPTION_BAND)

# The Workshop takes a square preview of 256 or 512 pixels, at most this many bytes
# (SteamWorkshopItem.validatePreviewImage); the mod list draws the poster at 200 square.
POSTER_SIZE = 512
PREVIEW_BYTES = 1_024_000
# The height of the poster's band with the mod's name, below its scene.
POSTER_BAND = 120

# The mod list draws the icon at about 22 pixels, the load order list at about 28, with linear
# filtering and no mipmaps (getTexture loads it without them). Drawn pixel by pixel at MOD_ICON
# and saved doubled with hard edges, each screen pixel blends at most two of the drawing's pixels,
# where shrunk from MOD_ICON itself a one-pixel line smears into its neighbours. Larger fonts draw
# it larger, which the doubled size also covers.
MOD_ICON = 32


def font(size, weight="Regular"):
    """NotoSans at size pixels; weight is one of its named instances, such as "SemiBold"."""
    face = ImageFont.truetype(str(FONT), size)
    face.set_variation_by_name(weight)
    return face


def sized(n, k):
    """n pixels of a README layout drawn k times its size, for the gallery's larger pages."""
    return round(n * k)


def pixels(image, factor):
    return image.resize((image.width * factor, image.height * factor), Image.NEAREST)


def scaled(image, factor):
    """image scaled by factor, through a whole-number nearest-neighbour enlargement first when it
    grows, which keeps captured interface text sharper than scaling straight to it."""
    if factor > 1:
        image = pixels(image, math.ceil(factor * 2))
        factor /= math.ceil(factor * 2)
    return image.resize((round(image.width * factor), round(image.height * factor)), Image.LANCZOS)


def fit(image, width, height):
    """image scaled to the largest size within width by height."""
    return scaled(image, min(width / image.width, height / image.height))


def cover(image, size):
    """image scaled to the smallest size that covers size, cropped to it about its middle."""
    factor = max(size[0] / image.width, size[1] / image.height)
    image = scaled(image, factor)
    left, top = (image.width - size[0]) // 2, (image.height - size[1]) // 2
    return image.crop((left, top, left + size[0], top + size[1]))


def full_width(image, width=WIDTH):
    """A world capture at the images' width; on a high-density display it comes out larger."""
    return image if image.width == width else scaled(image, width / image.width)


def trim(image, pad=0):
    """image cropped to what isn't transparent, with pad pixels around it."""
    left, top, right, bottom = image.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()
    return image.crop((left - pad, top - pad, right + pad, bottom + pad))


def rounded(image, radius):
    """image with its corners rounded off."""
    image = image.convert("RGBA")
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, image.width - 1, image.height - 1), radius, fill=255)
    image.putalpha(Image.composite(image.getchannel("A"), mask, mask))
    return image


def canvas(height, width=WIDTH):
    """A dark card with a faint vertical gradient."""
    image = Image.new("RGBA", (width, height), BACKGROUND + (255,))
    shade = Image.linear_gradient("L").resize((width, height)).point(lambda v: v * 0.35)
    image.paste(Image.new("RGBA", (width, height), (12, 13, 16, 255)), (0, 0), shade)
    return image


def paste(base, image, centre, shadow=True):
    """Pastes image centred on centre, over a soft shadow of itself."""
    x, y = round(centre[0] - image.width / 2), round(centre[1] - image.height / 2)
    if shadow:
        alpha = image.getchannel("A").point(lambda a: a * 0.6)
        blur = Image.new("RGBA", (image.width + 40, image.height + 40), (0, 0, 0, 0))
        blur.paste(Image.new("RGBA", image.size, (0, 0, 0, 255)), (20, 20), alpha)
        blur = blur.filter(ImageFilter.GaussianBlur(10))
        base.alpha_composite(blur, (x - 20 + 4, y - 20 + 8))
    base.alpha_composite(image, (x, y))


def wrap(string, face, width, split_words=False):
    """Splits string into lines no wider than width, breaking at spaces, and with split_words also
    after the hyphens and slashes of a word too wide for a line of its own."""
    lines = []
    for word in string.split():
        parts = [word]
        if split_words and face.getlength(word) > width:
            parts = [part for part in re.split(r"(?<=[-/])", word) if part]
        for i, part in enumerate(parts):
            joined = lines[-1] + ("" if i else " ") + part if lines else None
            if joined and face.getlength(joined) <= width:
                lines[-1] = joined
            else:
                lines.append(part)
    return "\n".join(lines)


def text(base, xy, string, size, weight="Regular", fill=TEXT, anchor="la", width=None):
    """Draws string, wrapped to width if given, and returns its box. An anchor centred across
    ("m…") centres every line."""
    face = font(size, weight)
    if width:
        string = wrap(string, face, width)
    ImageDraw.Draw(base).multiline_text(xy, string, font=face, fill=fill, anchor=anchor,
                                        align="center" if anchor[0] == "m" else "left", spacing=3)
    return ImageDraw.Draw(base).multiline_textbbox(xy, string, font=face, anchor=anchor, spacing=3)


def panel(base, box, accent=None, k=1):
    """A rounded panel, with a bar of accent along its top if given."""
    draw = ImageDraw.Draw(base)
    draw.rounded_rectangle(box, sized(18, k), fill=PANEL + (255,))
    if accent:
        draw.rectangle((box[0] + sized(28, k), box[1], box[2] - sized(28, k), box[1] + sized(5, k)),
                       fill=accent + (255,))


def badge(base, xy, string, k=1):
    """A small pill with string in it, its top right corner at xy."""
    face = font(sized(16, k), "Bold")
    w = face.getlength(string) + sized(14, k)
    box = (xy[0] - w, xy[1], xy[0], xy[1] + sized(22, k))
    ImageDraw.Draw(base).rounded_rectangle(box, sized(11, k), fill=(14, 15, 18, 235))
    ImageDraw.Draw(base).text(((box[0] + box[2]) / 2, box[1] + sized(11, k)), string, font=face, fill=TEXT,
                              anchor="mm")


def caption(base, xy, string, k=1):
    """A dark pill with a caption in it, its top left corner at xy, to sit on a world capture."""
    face = font(sized(24, k), "SemiBold")
    w = face.getlength(string) + sized(36, k)
    box = (xy[0], xy[1], xy[0] + w, xy[1] + sized(44, k))
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    ImageDraw.Draw(overlay).rounded_rectangle(box, sized(22, k), fill=(12, 13, 16, 215))
    base.alpha_composite(overlay)
    ImageDraw.Draw(base).text((box[0] + sized(18, k), box[1] + sized(22, k)), string, font=face, fill=TEXT,
                              anchor="lm")


def arrow(base, centre, colour=MUTED, k=1):
    """An arrow pointing right, centred on centre."""
    x, y = centre
    draw = ImageDraw.Draw(base)
    draw.rectangle((x - sized(22, k), y - sized(4, k), x + sized(6, k), y + sized(4, k)), fill=colour)
    draw.polygon([(x + sized(4, k), y - sized(14, k)), (x + sized(22, k), y), (x + sized(4, k), y + sized(14, k))],
                 fill=colour)


def title_over(image, title, size, line=None):
    """The mod's name over a world capture's left side, a word to a line, darkened behind it and
    clear by the middle, where the capture's subject should start; line, if given, goes under it
    in a smaller, muted face. Draws on image and returns the box of what it wrote."""
    shade = Image.linear_gradient("L").rotate(90, expand=True).resize(image.size)
    shade = shade.point(lambda v: max(0, min(235, round((140 - v) * 3.3))))
    image.paste(Image.new("RGBA", image.size, (12, 13, 16, 255)), (0, 0), shade)
    title = "\n".join(title.split())
    left = round(size * 5 / 7)
    xy = (left, image.height / 2 - round(size * 5 / 21))
    face = font(size, "Bold")
    ImageDraw.Draw(image).multiline_text(xy, title, font=face, fill=TEXT, anchor="lm", spacing=round(size / 14))
    box = ImageDraw.Draw(image).multiline_textbbox(xy, title, font=face, anchor="lm", spacing=round(size / 14))
    if line:
        box = text(image, (left + round(size / 21), box[3] + round(size * 11 / 42)), line, round(size * 5 / 14),
                   "Medium", MUTED)
    return box


def save(image, path):
    """Saves a README image as PNG."""
    assert image.width == WIDTH, f"{Path(path).name} is {image.width} pixels wide, not {WIDTH}"
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(path, optimize=True)
    wrote(path, image.size)


def wrote(path, size):
    print(f"promo: {os.path.relpath(path)} {size[0]}x{size[1]} {Path(path).stat().st_size} bytes")


class Captures:
    """A captures folder and its promo.json."""

    def __init__(self, folder):
        self.folder = Path(folder)
        self.promo = json.loads((self.folder / "promo.json").read_text())
        self.items = self.promo.get("items", [])
        self.recipes = self.promo.get("recipes", [])
        self.strings = self.promo.get("strings", {})
        self.models = {model["name"]: model["box"] for model in self.promo.get("models", [])}
        self.by_type = {item["fullType"]: item for item in self.items}
        self.builds = {recipe["id"]: recipe["build"] for recipe in self.recipes if recipe.get("build")}

    def __call__(self, name):
        """The capture <name>.png."""
        path = self.folder / f"{name}.png"
        assert path.exists(), f"there is no capture {name}: is its group in the last capture run?"
        return Image.open(path).convert("RGBA")

    def icon(self, key, size):
        """An icon scaled by the largest whole number that keeps it within size, or, where that
        leaves it at three quarters of size or less (the build menu's 48-pixel icons in a 64-pixel
        slot), smoothly to size."""
        image = self(key)
        factor = max(1, size // max(image.size))
        if max(image.size) * factor <= size * 3 / 4:
            return image.resize((round(image.width * size / max(image.size)),
                                 round(image.height * size / max(image.size))), Image.LANCZOS)
        return pixels(image, factor)

    def thing(self, key):
        """An item by its full type, or what a build menu recipe builds by the recipe's id: its
        name and its icon's capture."""
        found = self.by_type.get(key) or self.builds.get(key)
        assert found, f"{key} is neither an item nor a build menu recipe in promo.json"
        return found


# Item sheets ------------------------------------------------------------------------------------
# Each card is the item's icon over its name; with models, the item's model as it lies on the
# ground, with MODEL_PADDING of its size around it and no taller than MODEL_H, over its icon and
# its name side by side.
MODEL_PADDING = 0.12
MODEL_H = 120
ITEM_PAD = 8
ICON = 64
# An icon card's icon: three times an item's 32 pixels, twice a build icon's 48.
ICON_CARD = 96
NAME_SIZE = 16


def on_floor(image, item_box, margin):
    """image on a canvas margin wider on every side, the extra laid with tiles of the bare floor
    above the item, so that a frame can run past the capture's edges."""
    tile = image.crop((0, 0, image.width, item_box[1]))
    floor = Image.new("RGB", (image.width + 2 * margin, image.height + 2 * margin))
    for y in range(0, floor.height, tile.height):
        for x in range(0, floor.width, tile.width):
            floor.paste(tile, (x, y))
    floor.paste(image, (margin, margin))
    return floor


def name_block(name, width, k=1, centred=False):
    """The name wrapped to width, and how tall it stands."""
    face = font(sized(NAME_SIZE, k), "SemiBold")
    wrapped = wrap(name, face, width, split_words=True)
    box = ImageDraw.Draw(Image.new("L", (1, 1))).multiline_textbbox((0, 0), wrapped, font=face, spacing=3,
                                                                    align="center" if centred else "left")
    assert box[2] <= width, f"{name} is too wide for its card"
    return wrapped, box[3]


class ItemSheet:
    """The mod's items, and anything else that has a name and an icon (a build menu recipe's
    result, by the recipe's id), in rows of (caption, keys) by what they're for. Every item in
    promo.json must be in a row. With models, each card shows the item's model_<Module>_<Type>
    capture, framed from its box in promo.json's models."""

    def __init__(self, captures, rows, models=False):
        self.captures, self.rows, self.models = captures, rows, models
        placed = [key for _, keys in rows for key in keys]
        for key in placed:
            captures.thing(key)
        missing = set(captures.by_type) - set(placed)
        assert not missing, f"the item sheet has no place for {sorted(missing)}"
        assert len(placed) == len(set(placed)), "the item sheet shows an item twice"

    def framed_model(self, key, size):
        """The model capture around the item's box, with MODEL_PADDING on every side, scaled to fit
        inside size and centred in it."""
        image = self.captures(key).convert("RGB")
        left, top, right, bottom = item_box = self.captures.models[key]
        scale = min(size[0] / ((right - left) * (1 + 2 * MODEL_PADDING)),
                    size[1] / ((bottom - top) * (1 + 2 * MODEL_PADDING)))
        w, h = size[0] / scale, size[1] / scale
        x, y = (left + right - w) / 2, (top + bottom - h) / 2
        margin = math.ceil(max(0, -x, -y, x + w - image.width, y + h - image.height))
        if margin:
            image = on_floor(image, item_box, margin)
        return image.resize(size, Image.LANCZOS, box=(x + margin, y + margin, x + margin + w, y + margin + h))

    def card_height(self, names, k):
        pad = sized(ITEM_PAD, k)
        tallest = max(height for _, height in names)
        if self.models:
            return 3 * pad + sized(MODEL_H, k) + max(sized(ICON, k), tallest)
        return 3 * pad + sized(ICON_CARD, k) + tallest

    def card(self, image, key, name, box, k):
        pad = sized(ITEM_PAD, k)
        left, top, right = round(box[0]) + pad, box[1] + pad, round(box[2]) - pad
        thing = self.captures.thing(key)
        wrapped, height = name
        if not self.models:
            icon_size = sized(ICON_CARD, k)
            paste(image, self.captures.icon(thing["icon"], icon_size), ((left + right) / 2, top + icon_size / 2),
                  shadow=False)
            text(image, ((left + right) / 2, top + icon_size + pad), wrapped, sized(NAME_SIZE, k), "SemiBold",
                 anchor="ma")
            return
        icon_size, model_h = sized(ICON, k), sized(MODEL_H, k)
        size = (right - left, model_h)
        model = "model_" + key.replace(".", "_")
        image.alpha_composite(rounded(self.framed_model(model, size), sized(12, k)), (left, top))
        row = top + model_h + pad
        paste(image, self.captures.icon(thing["icon"], icon_size), (left + icon_size / 2, row + icon_size / 2),
              shadow=False)
        text(image, (left + icon_size + pad, row + max(0, (icon_size - height) / 2)), wrapped, sized(NAME_SIZE, k),
             "SemiBold")

    def draw(self, rows=None, width=WIDTH, columns=6, k=1, height=None):
        """The rows (by default all of them), each under its caption, each line of cards as tall
        as its longest name needs, drawn k times the README's size and centred in height if
        given."""
        rows = rows or self.rows
        pad, inset = sized(ITEM_PAD, k), sized(6, k)
        column = (width - 20) // columns
        name_width = column - 2 * inset - 2 * pad - (0 if not self.models else pad + sized(ICON, k))
        heading, gap = sized(44, k), sized(12, k)
        sections = []
        for title, keys in rows:
            lines = []
            for start in range(0, len(keys), columns):
                cards = [(key, name_block(self.captures.thing(key)["name"], name_width, k, not self.models))
                         for key in keys[start:start + columns]]
                lines.append((cards, self.card_height([name for _, name in cards], k)))
            sections.append((title, lines))
        needed = 20 + heading * len(sections) + sum(h + gap for _, lines in sections for _, h in lines)
        image = canvas(height or needed, width)
        assert needed <= image.height, f"{rows[0][0]} and the rest are too tall for the page"
        top = 20 + (image.height - needed) // 2
        for title, lines in sections:
            text(image, (30, top + heading / 2), title, sized(22, k), "SemiBold", MUTED, "lm")
            top += heading
            for cards, line_height in lines:
                left0 = (width - column * len(cards)) / 2
                for c, (key, name) in enumerate(cards):
                    left = left0 + c * column
                    box = (left + inset, top, left + column - inset, top + line_height)
                    panel(image, box, k=k)
                    self.card(image, key, name, box, k)
                top += line_height + gap
        return image

    def pages(self, pages, k=1):
        """Gallery pictures of the sheet: for each (file name, caption, row captions, columns), a
        page of those rows k times the README's size. Every row must be on one page."""
        by_title = dict(self.rows)
        shown = [title for _, _, titles, _ in pages for title in titles]
        assert sorted(shown) == sorted(by_title), f"the gallery shows rows {shown} of {list(by_title)}"
        return [(name, page(caption_text, self.draw([(t, by_title[t]) for t in titles], PAGE[0], columns, k,
                                                    PAGE[1])))
                for name, caption_text, titles, columns in pages]


# Recipe sheets ----------------------------------------------------------------------------------
# Each card is the recipe's name, skills, how it's learned and its tools in a column on the left,
# then a slot per input, an arrow and a slot per result. Cards share a row wherever they fit, and
# each row is as tall as its tallest card's contents.
CARD_GAP = 12
CARD_PAD = 16
NAME_W = 168
SLOT = 72
ARROW_W = 30


def unique_names(items):
    """The items, dropping any whose name an earlier one already shows."""
    seen, kept = set(), []
    for item in items:
        if item["name"] not in seen:
            seen.add(item["name"])
            kept.append(item)
    return kept


def alternatives(items):
    """What else an input line takes instead of its first item: "or Glue", or "or 4 more"."""
    others = unique_names(items)[1:]
    if not others:
        return ""
    return f"or {others[0]['name']}" if len(others) == 1 else f"or {len(others)} more"


def slot_caption(slot):
    """What goes under an item's name: the fluid it holds or the uses of a drainable item it takes,
    and what else the line takes instead."""
    words = []
    if slot.get("fluid"):
        words.append(f"{slot['litres']:g} L {slot['fluid']}")
    elif slot.get("uses"):
        words.append(f"{slot['count']} use" + ("" if slot["count"] == 1 else "s"))
    if slot.get("others"):
        words.append(slot["others"])
    return ", ".join(words)


def learn_line(recipe):
    """How the recipe is learned: the magazines that teach it, the items whose research teaches
    it, among them often its own result, and the skill level at which a character works it out
    alone."""
    learn = recipe["learn"]
    if not learn["needed"]:
        return "No need to learn it"
    ways = []
    if learn["magazines"]:
        ways.append("from " + ", or ".join(name.split(":")[0] for name in learn["magazines"]))
    results = {item["name"] for item in recipe["outputs"]}
    research = [name for name in learn["research"] if name not in results]
    if len(research) < len(learn["research"]):
        research.append("what it makes")
    if research:
        ways.append("by researching " + " or ".join(research))
    ways += [f"at {s['name']} {s['level']}" for s in learn["auto"]]
    if learn.get("autoAll"):
        ways.append("at " + " and ".join(f"{s['name']} {s['level']}" for s in learn["autoAll"]))
    return "Learn " + ", or ".join(ways)


def first_fit(cards, row_w, gap):
    """Packs (order, (recipe, parts, width)) pairs into rows as wide as row_w, each into the first
    row with room for it, and returns the rows and the cards in each in their order."""
    rows = []
    for order, card in cards:
        assert card[2] <= row_w, f"{card[0]['id']} is too wide for the image"
        row = next((row for row in rows if row[1] + gap + card[2] <= row_w), None)
        if row:
            row[0].append((order, card))
            row[1] += gap + card[2]
        else:
            rows.append([[(order, card)], card[2]])
    return [[card for _, card in sorted(row)] for row, _ in sorted(rows, key=lambda row: min(row[0]))]


def card_rows(cards, row_w, gap):
    """The section's cards in rows, in the section's order unless packing the widest first takes
    fewer rows."""
    in_order = first_fit(list(enumerate(cards)), row_w, gap)
    widest_first = first_fit(sorted(enumerate(cards), key=lambda pair: -pair[1][2]), row_w, gap)
    return widest_first if len(widest_first) < len(in_order) else in_order


class RecipeSheet:
    """The mod's recipes as cards, in sections of (caption, recipe ids) by what they're for. Every
    recipe in promo.json must be in exactly one section. accents gives a section's cards the
    colour along their top by its caption, else accent. results gives the item a recipe whose
    OnCreate makes it shows as its result, by recipe id and full type, since no output line names
    it; a recipe that improves an item it keeps shows that item without one."""

    def __init__(self, captures, sections, accent, accents=None, results=None):
        self.captures, self.sections = captures, sections
        self.results = results or {}
        placed = [i for _, ids in sections for i in ids]
        game = [r["id"] for r in captures.recipes]
        assert sorted(placed) == sorted(game), f"the recipe sheet places {sorted(placed)}, the game has {sorted(game)}"
        self.by_id = {r["id"]: r for r in captures.recipes}
        self.accent = {i: (accents or {}).get(title, accent) for title, ids in sections for i in ids}

    def parts(self, recipe):
        """The recipe's tools, by name, and its inputs and results as slots, { item, count, uses,
        others, fluid, litres }. Tools are what it keeps without working on. Lines that take the
        same fluid from the same container make one slot, lines that pour a fluid into an empty
        container are results, and a recipe without an output line shows what it gives back: what
        it builds, for a build menu recipe, its results entry, or the item it keeps and works on.
        A recipe with no inputs and no outputs is only learned, for something a menu offers once
        the character knows it, and has no slots."""
        learned_only = not recipe["inputs"] and not recipe["outputs"] and not recipe.get("build")
        if learned_only and recipe["id"] not in self.results:
            return [], [], []
        no_output = not recipe["outputs"] and not any(entry.get("fills") for entry in recipe["inputs"])
        subject = None
        if no_output and not recipe.get("build") and recipe["id"] not in self.results:
            subject = next((e for e in recipe["inputs"] if e["keep"] and not e["tag"] and not e.get("fluid")), None)
            assert subject, f"{recipe['id']} has no output and keeps nothing it works on: give it a result"
        tools, inputs, results = [], [], []
        for entry in recipe["inputs"]:
            fluid = entry.get("fluid") or entry.get("fills")
            item = entry["items"][0]
            if fluid:
                target = results if entry.get("fills") else inputs
                last = target[-1] if target else None
                if last and last.get("fluid") == fluid["name"] and last["item"]["icon"] == item["icon"]:
                    last["litres"] += fluid["litres"]
                else:
                    target.append({"item": item, "fluid": fluid["name"], "litres": fluid["litres"]})
            elif entry["keep"] and entry is not subject:
                tools.append(" ".join(filter(None, [item["name"], alternatives(entry["items"])])))
            else:
                inputs.append({"item": item, "count": item.get("count") or entry["count"], "uses": entry["uses"],
                               "others": alternatives(entry["items"])})
        if no_output:
            given = self.results.get(recipe["id"])
            built = recipe.get("build")
            results.insert(0, {"item": built or (self.captures.by_type[given] if given else subject["items"][0])})
        outputs = [{"item": item, "count": item["count"]} for item in recipe["outputs"]]
        return tools, inputs, outputs + results

    def draw_slot(self, base, slot, x, top, k=1):
        """A slot's icon centred on x with its name below, a badge with how many whole items, and a
        caption. Returns the bottom of what it drew."""
        item, count = slot["item"], slot.get("count")
        slot_w = sized(SLOT, k)
        paste(base, self.captures.icon(item["icon"], sized(64, k)), (x, top + sized(46, k)), shadow=False)
        if count and count > 1 and not slot.get("uses"):
            badge(base, (x + sized(38, k), top + sized(10, k)), f"×{count}", k)
        box = text(base, (x, top + sized(84, k)), item["name"], sized(13, k), "Medium", TEXT, "ma",
                   width=slot_w - sized(6, k))
        caption_text = slot_caption(slot)
        if caption_text:
            box = text(base, (x, box[3] + sized(3, k)), caption_text, sized(12, k), "Medium", MUTED, "ma",
                       width=slot_w - sized(4, k))
        return box[3]

    @staticmethod
    def card_width(parts, k=1):
        _, inputs, results = parts
        if not inputs and not results:
            return 2 * sized(CARD_PAD, k) + sized(NAME_W, k)
        return (2 * sized(CARD_PAD, k) + sized(NAME_W, k) + sized(14, k)
                + (len(inputs) + len(results)) * sized(SLOT, k) + sized(ARROW_W, k))

    def card(self, base, recipe, parts, box, k=1):
        """Draws the card into box and returns how far down its contents reach. A build menu recipe
        says so under its name."""
        left, top, right, bottom = box
        panel(base, box, self.accent[recipe["id"]], k)
        tools, inputs, results = parts
        pad, name_w, slot_w, arrow_w = sized(CARD_PAD, k), sized(NAME_W, k), sized(SLOT, k), sized(ARROW_W, k)
        x = left + pad
        lines = text(base, (x, top + sized(16, k)), recipe["name"], sized(17, k), "Bold", width=name_w)
        skills = "  ·  ".join(f"{s['name']} {s['level']}" for s in recipe["skills"])
        built = "Build menu" if recipe.get("build") else ""
        for line, size in [(built, 13), (skills, 13), (learn_line(recipe), 12),
                           ("Tools: " + ", ".join(tools) if tools else "", 12)]:
            if line:
                lines = text(base, (x, lines[3] + sized(6, k)), line, sized(size, k), "Medium", MUTED, width=name_w)
        lowest = lines[3]
        if not inputs and not results:
            return lowest
        x = left + pad + name_w + sized(14, k) + slot_w / 2
        for slot in inputs:
            lowest = max(lowest, self.draw_slot(base, slot, x, top, k))
            x += slot_w
        arrow(base, (x - slot_w / 2 + arrow_w / 2, top + sized(46, k)), k=k)
        x += arrow_w
        for slot in results:
            lowest = max(lowest, self.draw_slot(base, slot, x, top, k))
            x += slot_w
        assert lowest <= bottom - sized(10, k), f"{recipe['id']} runs past the bottom of its card"
        assert x - slot_w / 2 <= right - pad + 1, f"{recipe['id']} is too wide for its card"
        return lowest

    def card_height(self, recipe, parts, width, k=1):
        """How tall the card must be to hold its contents, found by drawing it on a scratch image."""
        scratch = Image.new("RGBA", (width, sized(1000, k)))
        return round(self.card(scratch, recipe, parts, (0, 0, width, sized(1000, k)), k)) + sized(CARD_PAD, k)

    def draw(self, sections=None, width=WIDTH, k=1, height=None):
        """The sections' cards (by default all of them), each section under its caption unless
        that is None, drawn k times the README's size and centred in height if given."""
        sections = sections or self.sections
        row_w, gap = width - 40, sized(CARD_GAP, k)
        laid = []
        for title, ids in sections:
            cards = []
            for i in ids:
                parts = self.parts(self.by_id[i])
                cards.append((self.by_id[i], parts, self.card_width(parts, k)))
            laid.append((title, card_rows(cards, row_w, gap)))
        heading = sized(52, k)
        heights = [[max(self.card_height(*card, k) for card in row) for row in rows] for _, rows in laid]
        needed = 20 + sum(heading for title, _ in laid if title) + sum(h + gap for hs in heights for h in hs)
        image = canvas(height or needed, width)
        assert needed <= image.height, f"the recipes from {sections[0][1][0]} on are too tall for the page"
        top = 20 + (image.height - needed) // 2
        for (title, rows), row_heights in zip(laid, heights):
            if title:
                text(image, (30, top + heading / 2), title, sized(22, k), "SemiBold", MUTED, "lm")
                top += heading
            for row, row_height in zip(rows, row_heights):
                # The row's spare width goes to its cards evenly, so every row spans the image.
                spare = (row_w - sum(card[2] for card in row) - gap * (len(row) - 1)) / len(row)
                left = 20
                for recipe, parts, card_w in row:
                    self.card(image, recipe, parts, (left, top, left + card_w + spare, top + row_height), k)
                    left += card_w + spare + gap
                top += row_height + gap
        return image

    def pages(self, pages, k=1):
        """Gallery pictures of the sheet: for each (file name, caption, [(section caption, slice of
        its ids)]), a page of those recipes k times the README's size, under the page's caption
        alone. Every recipe must be on exactly one page."""
        by_title = dict(self.sections)
        laid = [(name, caption_text, [(None, by_title[title][part]) for title, part in parts])
                for name, caption_text, parts in pages]
        shown = sorted(i for _, _, sections in laid for _, ids in sections for i in ids)
        assert shown == sorted(self.by_id), "the gallery must show every recipe once"
        return [(name, page(caption_text, self.draw(sections, PAGE[0], k, PAGE[1])))
                for name, caption_text, sections in laid]


# Gallery ----------------------------------------------------------------------------------------


def page(caption_text, content):
    """A gallery picture: its caption in the band across the top, over content the size of PAGE."""
    assert content.size == PAGE, f"{caption_text!r} has a page of {content.size}, not {PAGE}"
    image = Image.new("RGBA", GALLERY_SIZE, BACKGROUND + (255,))
    image.alpha_composite(content.convert("RGBA"), (0, CAPTION_BAND))
    face = font(CAPTION_SIZE, "Bold")
    assert face.getlength(caption_text) <= GALLERY_SIZE[0] - 120, f"{caption_text!r} is too wide for the band"
    ImageDraw.Draw(image).text((GALLERY_SIZE[0] / 2, CAPTION_BAND / 2), caption_text, font=face, fill=TEXT,
                               anchor="mm")
    return image


def hero(shot, title, size=132):
    """A page of the shot under the mod's name, covering the page: across its width, standing on
    its foot, or for a shot wider than the page's shape, up its height, about its middle."""
    shot = scaled(shot, max(PAGE[0] / shot.width, PAGE[1] / shot.height))
    left = (shot.width - PAGE[0]) // 2
    shot = shot.crop((left, shot.height - PAGE[1], left + PAGE[0], shot.height))
    title_over(shot, title, size)
    return shot


def shot_page(shot, shadow=True):
    """A capture centred on the page, no larger than it."""
    assert shot.height <= PAGE[1] and shot.width <= PAGE[0], f"a shot of {shot.size} is larger than the page"
    image = canvas(PAGE[1], PAGE[0])
    paste(image, shot, (PAGE[0] / 2, PAGE[1] / 2), shadow)
    return image


def save_gallery(pictures, folder):
    """Writes the (name, picture) pairs as NN-<name>.jpg, numbered in upload order, and deletes
    anything else in the folder, since dev/workshop-gallery.sh uploads the folder whole."""
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    written = set()
    for number, (name, picture) in enumerate(pictures, 1):
        assert picture.size == GALLERY_SIZE, f"{name} is {picture.size}, not {GALLERY_SIZE}"
        path = folder / f"{number:02d}-{name}.jpg"
        # Full-resolution colour keeps the captions' and icons' edges clean.
        picture.convert("RGB").save(path, quality=90, subsampling=0, optimize=True)
        assert path.stat().st_size < GALLERY_BYTES, f"{path.name} is over the Workshop's {GALLERY_BYTES} bytes"
        written.add(path)
        wrote(path, picture.size)
    for path in folder.iterdir():
        if path not in written:
            path.unlink()


# Poster and icon --------------------------------------------------------------------------------


def poster(shot, title, line, accent, band=POSTER_BAND):
    """The poster and Workshop preview: the shot, scaled to cover the square above a band of band
    pixels, over the band with the mod's name, set as large as fits, and line, a few words on what
    the mod is about, in a smaller face. Steam shows the preview smallest at about 196 pixels
    across, where the name must still read."""
    image = Image.new("RGBA", (POSTER_SIZE, POSTER_SIZE), BACKGROUND + (255,))
    top = POSTER_SIZE - band
    image.alpha_composite(cover(shot, (POSTER_SIZE, top)))
    draw = ImageDraw.Draw(image)
    draw.line((0, top, POSTER_SIZE, top), fill=accent, width=3)
    size = 56
    while draw.textlength(title, font=font(size, "Bold")) > POSTER_SIZE - 2 * 32:
        size -= 1
    middle = POSTER_SIZE / 2
    draw.text((middle, top + band / 2), title, font=font(size, "Bold"), fill=TEXT, anchor="ms")
    draw.text((middle, top + band * 4 / 5), line, font=font(24, "Medium"), fill=MUTED, anchor="ms")
    return image


def save_poster(image, paths):
    """Saves the poster to each path: the mod's 42/poster.png, which mod.info's poster= names, and
    the repository's preview.png, which the game's uploader sends as the Workshop preview."""
    assert image.size == (POSTER_SIZE, POSTER_SIZE), f"the poster is {image.size}, not {POSTER_SIZE} square"
    for path in paths:
        path = Path(path)
        image.convert("RGB").save(path, optimize=True)
        assert path.stat().st_size <= PREVIEW_BYTES, f"{path.name} is over the Workshop's {PREVIEW_BYTES} bytes"
        wrote(path, image.size)


def save_mod_icon(image, path):
    """Saves a MOD_ICON-square drawing, with transparency and no background, as the mod list's
    icon, which mod.info's icon= names: doubled with hard edges (MOD_ICON says why)."""
    assert image.size == (MOD_ICON, MOD_ICON), f"the icon is {image.size}, not {MOD_ICON} square"
    pixels(image.convert("RGBA"), 2).save(path, optimize=True)
    wrote(path, (2 * MOD_ICON, 2 * MOD_ICON))
