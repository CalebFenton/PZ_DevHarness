# shellcheck shell=bash
# Sourced by a mod's art/models/make.sh, which runs its scripts with `blender [FILE.blend] SCRIPT`:
# Blender in the background on its factory settings, opening FILE.blend if given, then running
# SCRIPT. BLENDER overrides the Blender binary.
#
# Python salts hash() per process unless PYTHONHASHSEED fixes it, which Blender reads only with
# --python-use-system-env. A script whose output follows hash order, as an FBX export's does
# (lib/art/fbx.py), then writes the same bytes on every run, and every other script keeps it so.
#
# Blender exits 0 when a -P script raises unless --python-exit-code says otherwise, and a make.sh
# that carried on past a failed render would pack and preview whatever the failure left behind.

BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
export PYTHONHASHSEED=0

blender() {
    "$BLENDER" -b --factory-startup --python-use-system-env --python-exit-code 1 "${@:1:$#-1}" -P "${!#}"
}
