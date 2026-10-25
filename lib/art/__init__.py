"""What a tile and item mod's art/models builds its art with (docs/art.md). A mod's scripts put the
harness's lib folder on sys.path and import the modules they need:

    sys.path.insert(0, os.path.join(REPO, "dev", "harness", "lib"))
    from art import kit, render

kit, shading, render, preview and fbx run inside Blender, on its bundled Python and numpy;
tilefile and pack run on any Python 3.10, pack with Pillow. Nothing here names a mod: its paths,
prefixes, palette, builders and tile tables are the mod's, passed in.
"""
import os
import sys

# tilefile, pack and preview write and read the formats of the static check's readers. Last on the
# path, so none of the check's modules hides a mod's own of the same name (tiles.py, say).
sys.path.append(os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "check"))
