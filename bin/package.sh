#!/usr/bin/env bash
# Zips every mod for local testing into one file, REVIEW_DIR/mods.zip, laid out the way
# ~/Zomboid/mods (or the Windows equivalent) takes it: each mod repository beside this one that
# uses the harness (has a dev/harness.conf), with its libraries (LIBRARY_MODS) and its dev mod, and
# the harness mod once. Every folder is zipped from its repository's checkout, so it stops while
# one has uncommitted changes and prints the commit each folder comes from; --dirty zips them
# anyway. A mod's dev/package.sh sources this, and any mod's builds the same zip.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

DIRTY=false
[ "${1:-}" = --dirty ] && DIRTY=true
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/mods"
FOLDERS=() UNCOMMITTED=()

# Adds folder $2 of the zip from the mod folder $1. A folder two repositories both ship (a library,
# the harness mod) goes in once, and only while their copies are the same.
add() {
    local source="$1" folder="$2" link="$WORK/mods/$2" top commit
    if [ -L "$link" ]; then
        [ "$(readlink "$link")" = "$source" ] && return
        if ! diff -rq -x .DS_Store "$(readlink "$link")" "$source" > /dev/null; then
            echo "$folder differs between $(readlink "$link") and $source: check both out at the same commit" >&2
            exit 1
        fi
        return
    fi
    ln -s "$source" "$link"
    FOLDERS+=("$folder")
    top="$(git -C "$source" rev-parse --show-toplevel)"
    commit="$(git -C "$source" rev-parse --short HEAD)"
    if git -C "$source" status --porcelain -- . | grep -qv '\.DS_Store$'; then
        UNCOMMITTED+=("$folder ($top)")
        commit="$commit + uncommitted changes"
    fi
    printf '%-30s %-8s %s %s\n' "$folder" "$(mod_info "$source" modversion)" "${top#"$(dirname "$REPO")/"}" "$commit"
}

for repo in "$(dirname "$REPO")"/*/; do
    repo="${repo%/}"
    [ -f "$repo/dev/harness.conf" ] && [ -f "$repo/dev/harness/lib/harness.sh" ] || continue
    # Each repository describes its folders through its own harness, the way its runs load them.
    folders="$(bash -c '. "$1/dev/harness/lib/harness.sh"
        for i in ${LIBRARY_DIRS[@]+"${!LIBRARY_DIRS[@]}"}; do
            printf "%s\t%s\n" "${LIBRARY_DIRS[$i]}" "${LIBRARY_FOLDERS[$i]}"
        done
        printf "%s\t%s\n" "$MOD_DIR" "$MOD_FOLDER" "$DEV_MOD_DIR" "$DEV_MOD_FOLDER" \
            "$HARNESS_MOD_DIR" "$HARNESS_MOD_FOLDER"' _ "$repo")"
    while IFS=$'\t' read -r source folder; do
        add "$source" "$folder"
    done <<< "$folders"
done

if [ ${#UNCOMMITTED[@]} -gt 0 ] && ! $DIRTY; then
    printf 'uncommitted changes in %s\n' "${UNCOMMITTED[@]}" >&2
    echo "commit them, or pass --dirty to zip them anyway" >&2
    exit 1
fi
(cd "$WORK/mods" && zip -qrX "$WORK/mods.zip" "${FOLDERS[@]}" -x '*.DS_Store')
mkdir -p "$REVIEW_DIR"
mv "$WORK/mods.zip" "$REVIEW_DIR/mods.zip"
echo "wrote $REVIEW_DIR/mods.zip: unzip it into ~/Zomboid/mods"
