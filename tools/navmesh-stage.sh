#!/usr/bin/env bash
# navmesh-stage.sh - put a folder of navmeshes into the repo as one small .xz per file
# (world/navmesh/<name>.xz) and rewrite world/navmesh-manifest.sha256.
#
#   tools/navmesh-stage.sh <folder with zone*.nav, seams.json, pockets.json, roads.json>
#
# Why one file each: git stores identical files once, so a new Offline DAoC release that changes
# 3 of 103 meshes adds ~20 MB, not another 360 MB. A file whose SHA-256 already matches the
# manifest is NOT recompressed (xz output can differ between versions, which would defeat this).
# Run it after reading the new meshes out of the release zip (tools/world/rangezip.py).
# macOS: bash 3.2, shasum -a 256 and xz (brew install xz).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO/world/navmesh-manifest.sha256"
DEST="$REPO/world/navmesh"
SRC=${1:?"usage: $0 <folder with zone*.nav>"}
SET="${NAVMESH_SET:-$(sed -n 's/^# Navmesh set \([^:]*\):.*/\1/p' "$MANIFEST" | head -1)}"
SOURCE_NOTE="${NAVMESH_SOURCE_NOTE:-}"

compgen -G "$SRC/zone*.nav" >/dev/null || { echo "navmesh-stage: no zone*.nav in $SRC" >&2; exit 1; }
mkdir -p "$DEST"
# The manifest's own hash for a file, "" when it has none (no associative arrays in bash 3.2).
old_sum() { [[ -f $MANIFEST ]] && awk -v f="$1" '$1 !~ /^#/ && $2 == f {print $1; exit}' "$MANIFEST" || true; }

new="$(mktemp)"; trap 'rm -f "$new"' EXIT
changed=0; kept=0
for path in "$SRC"/zone*.nav "$SRC"/seams.json "$SRC"/pockets.json "$SRC"/roads.json; do
  [[ -f $path ]] || continue
  f=$(basename "$path"); sum=$(shasum -a 256 "$path" | cut -d' ' -f1)
  printf '%s  %s\n' "$sum" "$f" >>"$new"
  if [[ $(old_sum "$f") == "$sum" && -s $DEST/$f.xz ]]; then kept=$((kept + 1)); continue; fi
  xz -6 -T0 -c "$path" >"$DEST/$f.xz.tmp" && mv "$DEST/$f.xz.tmp" "$DEST/$f.xz"
  echo "staged $f"; changed=$((changed + 1))
done
# Drop meshes that are no longer in the set.
for x in "$DEST"/*.xz; do [[ -f $x ]] || continue; grep -q "  $(basename "$x" .xz)\$" "$new" || { echo "removed $(basename "$x")"; rm -f "$x"; }; done

if [[ $changed -gt 0 || ! -f $MANIFEST ]]; then
  header="$(grep '^#' "$MANIFEST" 2>/dev/null || echo "# Navmesh set ${SET:-unnamed}. sha256  file.")"
  { printf '%s\n' "$header"; LC_ALL=C sort -k2 "$new"; } >"$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
fi
echo "navmesh-stage: $changed staged, $kept unchanged. Now: git add world/navmesh world/navmesh-manifest.sha256"
