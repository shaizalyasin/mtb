#!/usr/bin/env bash
# Stage a study that is NOT on the public DataHub -- e.g. a public study that
# has been extended with institution-specific data -- into ./study so
# ./import-study.sh can load it.
#
#   ./add-local-study.sh <path-to-study-dir> [study-id]
#
# Copies the directory, strips macOS archive cruft (__MACOSX, ._* files), and
# repairs meta files that are missing a trailing newline, which the importer's
# line-wise parser needs.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

SRC="${1:?usage: ./add-local-study.sh <path-to-study-dir> [study-id]}"
SRC="${SRC%/}"

if [ ! -d "$SRC" ]; then
    echo "Not a directory: $SRC" >&2
    exit 1
fi

# Archives often unzip to <name>/<name>/; use the level that holds meta_study.txt.
if [ ! -f "$SRC/meta_study.txt" ] && [ -f "$SRC/$(basename "$SRC")/meta_study.txt" ]; then
    SRC="$SRC/$(basename "$SRC")"
    echo "Descending into $SRC (that is where meta_study.txt lives)"
fi

if [ ! -f "$SRC/meta_study.txt" ]; then
    echo "No meta_study.txt under $SRC" >&2
    exit 1
fi

STUDY_ID="${2:-$(sed -n 's/^cancer_study_identifier:[[:space:]]*//p' "$SRC/meta_study.txt" | head -n 1)}"
if [ -z "$STUDY_ID" ]; then
    echo "Could not determine the study id; pass it as the second argument" >&2
    exit 1
fi

DST="./study/$STUDY_ID"
rm -rf "$DST"
mkdir -p "$DST"
cp -r "$SRC"/. "$DST"/

find "$DST" -name '__MACOSX' -prune -exec rm -rf {} + 2>/dev/null || true
find "$DST" -name '._*' -delete 2>/dev/null || true

for f in "$DST"/meta_*.txt; do
    [ -f "$f" ] || continue
    if [ -n "$(tail -c 1 "$f")" ]; then
        printf '\n' >> "$f"
        echo "  fixed missing trailing newline: $(basename "$f")"
    fi
done

echo
echo "Staged '$STUDY_ID' at $DST ($(find "$DST" -type f | wc -l) files)."
echo "Import it with:  ./import-study.sh $STUDY_ID"
