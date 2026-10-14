#!/usr/bin/env bash
# Shows the mod's Workshop gallery, or with --upload replaces its images with WORKSHOP_GALLERY's
# (docs/workshop-page.md#the-gallery). The item is workshop.txt's id, so it must be published first.
# Needs python3 and Steam running, logged in to the account that owns the item. A mod's
# dev/workshop-gallery.sh sources this.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

usage="usage: $0 [--upload]"
upload=()
case "${1:-}" in
    "") ;;
    --upload) upload=(--upload "$REPO/${WORKSHOP_GALLERY:-art/promo/gallery}") ;;
    *) echo "$usage" >&2; exit 2 ;;
esac
item="$(sed -n 's/^id=//p' "$REPO/workshop.txt")"
[ -n "$item" ] || { echo "workshop.txt has no id: upload the mod from the game's Workshop screen first" >&2; exit 1; }
PYTHONDONTWRITEBYTECODE=1 exec python3 "$HARNESS/lib/gallery.py" --lib "$PZ/Java/libsteam_api.dylib" \
    --item "$item" ${upload[@]+"${upload[@]}"}
