"""Reads and writes texture packs (.pack), the sprite atlases of media/texturepacks.

The game knows a packed sprite by its bare name, globally: Texture.getSharedTexture drops the
directory and the .png from whatever it is asked for and tries the packs first.

The layout, from TexturePackDevice.initMetaData and TexturePackPage.loadFromPackFile; integers are
little endian int32, strings an int32 length then that many bytes, each read as one char:

    "PZPK", version 1            absent in old packs, which start at the page count
    page count
    each page:
        string name, sprite count, alpha flag
        each sprite: string name, x, y, w, h (its rect on the page), offset x, offset y (where
                     that rect sits in the full cell), cell width, cell height
        version 1: int32 length, then the page's PNG
        old:       the PNG, then the bytes EF BE AD DE

This writes only version 1. The old end marker is found by scanning for it, so an image whose
compressed bytes happened to contain it would be cut short.
"""
import os
import struct
from dataclasses import dataclass, field

MAGIC = b"PZPK"
OLD_END_MARKER = b"\xef\xbe\xad\xde"

_INT = struct.Struct("<i")
_RECT = struct.Struct("<8i")


@dataclass
class Sprite:
    name: str
    x: int
    y: int
    width: int
    height: int
    offset_x: int
    offset_y: int
    cell_width: int
    cell_height: int


@dataclass
class Page:
    name: str
    has_alpha: bool
    sprites: list = field(default_factory=list)
    # Where the page's PNG sits in the file, so a reader can skip it or slice it out.
    image_start: int = 0
    image_length: int = 0


def read_index(path):
    """The pages of a .pack and their sprites, without reading any image. Raises ValueError or
    EOFError on anything the game could not load either."""
    with open(path, "rb") as f:
        def take(n):
            data = f.read(n)
            if len(data) != n:
                raise EOFError("%s ends at byte %d" % (os.path.basename(path), f.tell()))
            return data

        def number():
            return _INT.unpack(take(4))[0]

        def string():
            return take(number()).decode("latin-1")

        version = 0
        if take(4) == MAGIC:
            version = number()
            if version != 1:
                raise ValueError("pack version %d, the game reads only 1" % version)
        else:
            f.seek(0)
        pages = []
        for _ in range(number()):
            page = Page(string(), False)
            count = number()
            page.has_alpha = number() != 0
            for _ in range(count):
                name = string()
                page.sprites.append(Sprite(name, *_RECT.unpack(take(_RECT.size))))
            if version:
                page.image_length = number()
                page.image_start = f.tell()
                f.seek(page.image_length, os.SEEK_CUR)
            else:
                page.image_start = f.tell()
                page.image_length = _find_end_marker(f) - page.image_start
                f.seek(len(OLD_END_MARKER), os.SEEK_CUR)
            pages.append(page)
        if f.tell() > os.fstat(f.fileno()).st_size:
            raise EOFError("%s is cut short inside its last image" % os.path.basename(path))
        return pages


def _find_end_marker(f):
    """Offset of the next old-style end marker, leaving the file there."""
    start = f.tell()
    tail = b""
    while True:
        chunk = f.read(1 << 16)
        if not chunk:
            raise EOFError("an old-style pack image has no end marker")
        window = tail + chunk
        found = window.find(OLD_END_MARKER)
        if found >= 0:
            at = f.tell() - len(window) + found
            f.seek(at)
            return at
        # Keep enough to catch a marker split across two chunks.
        tail = window[-(len(OLD_END_MARKER) - 1):]
        if f.tell() - start > 1 << 30:
            raise EOFError("no end marker in the first GiB of an old-style image")


def write_pack(path, page, png):
    """Write a single-page version 1 pack."""
    out = [MAGIC, _INT.pack(1), _INT.pack(1), _string(page.name),
           _INT.pack(len(page.sprites)), _INT.pack(1 if page.has_alpha else 0)]
    for s in page.sprites:
        out += [_string(s.name), _RECT.pack(s.x, s.y, s.width, s.height, s.offset_x, s.offset_y,
                                            s.cell_width, s.cell_height)]
    out += [_INT.pack(len(png)), png]
    with open(path, "wb") as f:
        f.write(b"".join(out))


def _string(text):
    data = text.encode("latin-1")
    return _INT.pack(len(data)) + data
