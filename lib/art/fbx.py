"""Exports FBX files that come out the same, byte for byte, from the same scene, so git shows only
what a change touched. Importing this module makes Blender's exporter so:

- The exporter gives each object the id hash() makes of its name (fbx_utils.py _key_to_uuid) and
  writes a hinge's animation curves in the order of a set hashed the same way (export_fbx_bin.py
  fbx_animations_do), and Python salts that hash per process unless PYTHONHASHSEED fixes it,
  which Blender reads only with --python-use-system-env (lib/blender.sh passes both). Without
  them the import exits.
- The exporter stamps each file with the time of writing; it gets a fixed one here.
- It writes a texture's path, absolute unless told otherwise, so each checkout would write
  different files: export a material without one, or pass path_mode="STRIP".
"""
import datetime
import functools
import sys

import bpy
from io_scene_fbx import export_fbx_bin

from . import kit

if sys.flags.hash_randomization:
    sys.exit("art.fbx: set PYTHONHASHSEED and pass --python-use-system-env (dev/harness/lib/blender.sh), or every FBX "
             "object id changes")
# The exporter's own hook for the creation time; it takes the time of writing without one.
if not isinstance(export_fbx_bin.fbx_header_elements, functools.partial):
    export_fbx_bin.fbx_header_elements = functools.partial(export_fbx_bin.fbx_header_elements,
                                                           time=datetime.datetime(2000, 1, 1))


def export(path, obj, *others, **options):
    """Writes `obj`, and `others` with it (an armature), to `path`: the selection only, in metres,
    without the leaf bones Blender would add, the scene's axes baked into the vertices unless
    `options` says otherwise. `options` are the exporter's (bpy.ops.export_scene.fbx)."""
    kit.select(obj, *others)
    options = {"object_types": {"MESH"}, "bake_space_transform": True, **options}
    bpy.ops.export_scene.fbx(filepath=path, use_selection=True, apply_scale_options="FBX_SCALE_ALL", add_leaf_bones=False,
                             **options)
