"""Builds a mod's texture pack (media/texturepacks/<name>.pack, in the static check's packs.py
format) from the tile sprites and icons render.py wrote. A mod's tools/pack_textures.py, a
`uv run --script` file that pins Pillow (two builds can compress the same pixels to different
bytes), names its pack and calls pack.

Every PNG of the two folders goes onto one fresh atlas page, so a deleted source leaves no stale
sprite behind. The game knows a packed sprite by its bare name, globally, so every name carries
the mod's to keep clear of other mods'. A tile sprite is trimmed to its visible pixels and records
where they sat in the full cell; an icon is stored whole, so it reports the size a loose PNG would.
Model textures stay loose (the static check's model-texture says why).
"""
import io
import os

from packs import Page, Sprite, read_index, write_pack

# Transparent pixels between sprites, so texture filtering never samples a neighbour.
GAP = 2
# The base game's own pages stop at this width.
PAGE_WIDTH = 1024


def load_sources(folder, trim):
    """(sprite name, image, offset in its cell, cell size) for every PNG in folder."""
    from PIL import Image

    sources = []
    for file_name in sorted(os.listdir(folder)):
        if not file_name.endswith(".png"):
            continue
        image = Image.open(os.path.join(folder, file_name)).convert("RGBA")
        cell = image.size
        offset = (0, 0)
        if trim:
            box = image.getbbox()
            if box is None:
                raise SystemExit("%s has no visible pixels" % file_name)
            image = image.crop(box)
            offset = box[:2]
        sources.append((file_name[:-len(".png")], image, offset, cell))
    return sources


def shelve(sizes):
    """Top-left corners for rects of these sizes, filled into rows across a page PAGE_WIDTH wide,
    and the page size that holds them. A row takes rects while each fits with a gap after it."""
    corners = []
    row_top = row_height = row_used = page_width = 0
    for width, height in sizes:
        if row_used and row_used + width + GAP > PAGE_WIDTH:
            row_top += row_height + GAP
            row_height = row_used = 0
        corners.append((row_used, row_top))
        page_width = max(page_width, row_used + width)
        row_used += width + GAP
        row_height = max(row_height, height)
    return corners, (page_width, row_top + row_height)


def pack(pack_file, page_name, trimmed_dir, whole_dir):
    """Writes `pack_file`, one page `page_name` of the PNGs in `trimmed_dir` (tile sprites, trimmed)
    and `whole_dir` (icons, whole), and reads it back."""
    from PIL import Image

    sources = load_sources(trimmed_dir, trim=True) + load_sources(whole_dir, trim=False)
    names = [source[0] for source in sources]
    repeated = sorted({name for name in names if names.count(name) > 1})
    if repeated:
        raise SystemExit("sprites named twice: %s" % ", ".join(repeated))
    # Tallest first, so each row's height is set by its first sprite and wastes little.
    sources.sort(key=lambda source: (-source[1].height, source[0]))
    corners, page_size = shelve([source[1].size for source in sources])

    atlas = Image.new("RGBA", page_size, (0, 0, 0, 0))
    page = Page(page_name, True)
    for (name, image, offset, cell), corner in zip(sources, corners):
        atlas.paste(image, corner)
        page.sprites.append(Sprite(name, *corner, *image.size, *offset, *cell))
    png = io.BytesIO()
    atlas.save(png, format="PNG", optimize=True)

    old_size = os.path.getsize(pack_file) if os.path.exists(pack_file) else 0
    os.makedirs(os.path.dirname(pack_file), exist_ok=True)
    write_pack(pack_file, page, png.getvalue())
    # Read the index back, so a pack the game would misread never ships.
    (written,) = read_index(pack_file)
    assert written.sprites == page.sprites and written.image_length == len(png.getvalue()), \
        "the pack does not read back as written"
    print("%d sprites on a %dx%d page; %s %d -> %d bytes"
          % (len(page.sprites), page_size[0], page_size[1], os.path.basename(pack_file), old_size,
             os.path.getsize(pack_file)))
