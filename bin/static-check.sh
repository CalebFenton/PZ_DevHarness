#!/usr/bin/env bash
# Checks the mod against the installed game without launching it (docs/static-check.md):
# check/GameProbe.java compiles every Lua file of the mod's libraries (the conf's LIBRARY_MODS),
# the mod, its dev mod and the harness mod with the game's own Kahlua compiler, then
# check/check.py cross-checks their translations, scripts, textures, sandbox options and Lua
# names, with the conf's CHECK_PLUGINS for the mod's own rules; and that the conf's TEST_MAP
# covers every file of the mods (lib/tests.py check).
# A mod's dev/static-check.sh sources this. Needs a JDK's javac (or JAVAC) and python3.
#
# CACHE overrides the cache dir (default: $TMPDIR/<CACHE_NAME>-check).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

BUILD="${CACHE:-$TMP_REAL/$CACHE_NAME-check}"
JAR="$PZ/Java/projectzomboid.jar"
API="$BUILD/game-api.txt"
mkdir -p "$BUILD"

compile_java "$HARNESS/check/GameProbe.java" "$BUILD"
# What Lua can reach changes only with the game, so the probe's API file is rebuilt with the jar.
probe_api=()
if [ "$JAR" -nt "$API" ] || [ "$BUILD/GameProbe.class" -nt "$API" ]; then
    probe_api=(--api "$JAR" "$API")
fi

# One "path<TAB>name" per Lua file; the name, from the mod's folder, a library's parent folder or
# the repository, is what errors show.
list_lua() {
    (cd "$1" && find "${@:2}" -name '*.lua' | sort | while read -r file; do
        printf '%s\t%s\n' "$1/$file" "$file"
    done)
}
# The version folders of mod folder $1 that exist, 42 first as it holds the mod.info, in parts,
# each named with $2 in front.
version_parts() {
    local part
    parts=()
    for part in 42 common; do
        if [ -d "$1/$part" ]; then
            parts+=("${2:-}$part")
        fi
    done
}
# A library is named from the folder it sits in, so its errors show which library they are in.
libraries=()
{
    for library in ${LIBRARY_DIRS[@]+"${LIBRARY_DIRS[@]}"}; do
        libraries+=(--library "$library")
        version_parts "$library" "$(basename "$library")/"
        list_lua "$(dirname "$library")" "${parts[@]}"
    done
    version_parts "$MOD_DIR"
    mod_parts=("${parts[@]}")
    list_lua "$MOD_DIR" "${mod_parts[@]}"
    list_lua "$REPO" "${DEV_MOD_DIR#"$REPO/"}" "${HARNESS_MOD_DIR#"$REPO/"}"
} > "$BUILD/lua-files.txt"

options=(--name "$MOD_FOLDER" ${libraries[@]+"${libraries[@]}"})
if declare -p CHECK_PLUGINS > /dev/null 2>&1; then
    for plugin in ${CHECK_PLUGINS[@]+"${CHECK_PLUGINS[@]}"}; do
        options+=(--plugin "$REPO/$plugin")
    done
fi
[ -z "${CHECK_ALL_LANGUAGES:-}" ] || options+=(--all-languages)
if declare -p OTHER_MOD_GLOBALS > /dev/null 2>&1; then
    for name in ${OTHER_MOD_GLOBALS[@]+"${OTHER_MOD_GLOBALS[@]}"}; do
        options+=(--other-global "$name")
    done
fi

status=0
# Kahlua reads stdlib.lua from the working directory.
(cd "$PZ/Java" && "$JAVA" -cp "$BUILD:$JAR" GameProbe ${probe_api[@]+"${probe_api[@]}"} "@$BUILD/lua-files.txt") \
    || status=1
PYTHONDONTWRITEBYTECODE=1 python3 "$HARNESS/check/check.py" --game "$PZ/Java" --api "$API" --cache "$BUILD" \
    "${options[@]}" "${mod_parts[@]/#/$MOD_DIR/}" "$DEV_MOD_DIR/42" "$HARNESS_MOD_DIR/42" || status=1
if [ -n "${WORKSHOP_REPO:-}" ]; then
    "$HARNESS/bin/workshop-txt.sh" --check || status=1
fi
tests_py check || status=1
exit $status
