#!/usr/bin/env bash
# Writes the mod's workshop.txt description from its README.md (docs/workshop-page.md), keeping the
# title, id, tags and visibility already there, and says how much of Steam's 8000 bytes it uses. A
# mod's dev/workshop-txt.sh sources this; --check writes nothing and fails when workshop.txt is out
# of date, as bin/static-check.sh runs it. Needs python3.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

options=(--repo "$WORKSHOP_REPO" --branch "${WORKSHOP_BRANCH:-master}")
for heading in ${WORKSHOP_SKIP[@]+"${WORKSHOP_SKIP[@]}"}; do
    options+=(--skip "$heading")
done
# The game's footer names each map folder too (SteamWorkshopItem.getSubmitDescription).
for folder in "$MOD_DIR"/*/media/maps/*/; do
    [ -d "$folder" ] && options+=(--map "$(basename "$folder")")
done
PYTHONDONTWRITEBYTECODE=1 exec python3 "$HARNESS/lib/workshop.py" "${options[@]}" "$@" \
    "$REPO/README.md" "$REPO/workshop.txt" "$MOD_ID"
