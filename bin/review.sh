#!/usr/bin/env bash
# Builds the README and player's guide review pages without launching the game: lays out the README
# images from the committed captures (art/promo/compose.py, when the mod has one) and renders
# REVIEW_DOCS the way GitHub shows them to self-contained HTML pages, the first also to a PDF. All of
# it lands in REVIEW_DIR (lib/harness.sh), named after the mod's folder:
#
#   <mod>-README.html, .pdf          and <mod>-<doc>.html for each other REVIEW_DOCS file
#   <mod>-art/index.html             with --art: the mod's art/models/preview.py review page
#
# bin/package.sh builds the mods' zip. Needs uv, pandoc and Google Chrome (CHROME overrides its
# path), and for --art Blender (BLENDER overrides its path). A mod's dev/review.sh sources this.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
. "$HARNESS/lib/blender.sh"

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
ART=false
[ "${1:-}" = --art ] && ART=true
NAME="$(mod_info "$MOD_DIR" name)"
VERSION="$(mod_info "$MOD_DIR" modversion)"
DOCS=(${REVIEW_DOCS[@]+"${REVIEW_DOCS[@]}"})
[ ${#DOCS[@]} -gt 0 ] || DOCS=(README.md)
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -x "$REPO/art/promo/compose.py" ] && "$REPO/art/promo/compose.py"

# The pages' images are embedded, so the HTML and the PDF stand alone wherever they are copied.
OUTPUTS=()
for doc in "${DOCS[@]}"; do
    page="$MOD_FOLDER-$(basename "$doc" .md).html"
    title="$NAME $VERSION"
    if [ "$doc" != README.md ]; then
        # A guide's heading names the mod first, as in "<mod>: player's guide".
        heading="$(sed -n '1s/^# //p' "$REPO/$doc")"
        title="$title: ${heading#"$NAME: "}"
    fi
    pandoc "$REPO/$doc" -f gfm -t html5 --standalone --embed-resources \
        --resource-path="$(dirname "$REPO/$doc")" --css="$HARNESS/lib/review.css" \
        --metadata pagetitle="$title" -o "$WORK/$page"
    OUTPUTS+=("$page")
done
PDF="${OUTPUTS[0]%.html}.pdf"
# A throwaway profile, so the run neither touches nor waits on a Chrome that is already open.
"$CHROME" --headless --disable-gpu --no-pdf-header-footer --user-data-dir="$WORK/chrome" \
    --print-to-pdf="$WORK/page.pdf" "file://$WORK/${OUTPUTS[0]}" 2>/dev/null
# review.css prints onto one tall page; crop it below the last text or image.
uv run -q --with pymupdf python - "$WORK/page.pdf" "$WORK/$PDF" <<'EOF'
import sys
import pymupdf
doc = pymupdf.open(sys.argv[1])
page = doc[-1]
bottom = max([b[3] for b in page.get_text("blocks")] + [i["bbox"][3] for i in page.get_image_info()])
page.set_cropbox(pymupdf.Rect(0, 0, page.rect.width, min(page.rect.height, bottom + 36)))
doc.save(sys.argv[2], garbage=3, deflate=True)
EOF
mkdir -p "$REVIEW_DIR"
for file in "${OUTPUTS[0]}" "$PDF" "${OUTPUTS[@]:1}"; do
    mv "$WORK/$file" "$REVIEW_DIR/$file"
    echo "wrote $REVIEW_DIR/$file"
done
if $ART; then
    PREVIEWS="$REVIEW_DIR/$MOD_FOLDER-art" blender "$REPO/art/models/preview.py" >/dev/null
    echo "wrote $REVIEW_DIR/$MOD_FOLDER-art/index.html"
fi
