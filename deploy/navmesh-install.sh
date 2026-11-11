#!/usr/bin/env bash
# navmesh-install.sh - install the navigation meshes (zone*.nav, plus the bots' seams.json,
# pockets.json and roads.json zone data) into this server folder's navmesh/.
# NPCs and bots need them to path around obstacles; without them they walk in straight lines.
#
#   ./navmesh-install.sh --from-xz <folder>      the source's world/navmesh: one <file>.xz per mesh,
#                                                checked against ../navmesh-manifest.sha256 beside it
#   ./navmesh-install.sh --from-dir <folder>     zone*.nav files from another OpenDAoC-based server
#   ./navmesh-install.sh --build-from-client <DAoC client folder>   NOT available on macOS (see README)
#
# `daoc server install` runs --from-xz with the navmeshes of the pinned source.
# macOS port of the Linux repo's tools/navmesh-unpack.sh and deploy/navmesh-install.sh: shasum -a 256
# instead of sha256sum, sysctl instead of nproc; --build-from-client stays unavailable (the
# generator needs Windows/Wine).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${DAOC_HOME:-$HERE}/navmesh"
DATA_FILES=(seams.json pockets.json roads.json)
work=""
die() { echo "navmesh-install: $*" >&2; exit 1; }

install_xz() {
  local src=$1 manifest
  [[ -d $src ]] || die "no such folder: $src"
  manifest="$(cd "$src/.." && pwd)/navmesh-manifest.sha256"
  [[ -f $manifest ]] || die "no navmesh-manifest.sha256 beside $src"
  compgen -G "$src/*.xz" >/dev/null || die "no *.xz navmeshes in $src"
  work=$(mktemp -d "${DEST%/}.install.XXXXXX")
  trap 'rm -rf "${work:-}"' EXIT
  echo "Unpacking $(grep -vc '^#' "$manifest") navmesh files ..."
  grep -v '^#' "$manifest" | awk '{print $2}' |
    xargs -P "$(sysctl -n hw.ncpu)" -I{} sh -c 'xz -dc "$1/$2.xz" > "$3/$2"' _ "$src" {} "$work"
  (cd "$work" && grep -v '^#' "$manifest" | shasum -a 256 --check --quiet) || die "navmeshes failed verification against $manifest"
  mkdir -p "$DEST"
  mv -f "$work"/zone*.nav "$DEST/"
  for f in "${DATA_FILES[@]}"; do if [[ -f $work/$f ]]; then mv -f "$work/$f" "$DEST/"; fi; done
  cp "$manifest" "$DEST/MANIFEST.sha256"
  echo "Installed $(ls "$DEST"/zone*.nav | wc -l | tr -d ' ') navmeshes into $DEST"
}

case "${1:-}" in
  --from-xz)
    install_xz "${2:?"usage: $0 --from-xz <folder with *.xz>"}"
    ;;
  --from-dir)
    src=${2:?"usage: $0 --from-dir <folder with zone*.nav>"}
    compgen -G "$src/zone*.nav" >/dev/null || die "no zone*.nav files in $src"
    mkdir -p "$DEST"
    count=0
    for f in "$src"/zone*.nav; do
      [[ -s $f ]] || die "empty navmesh file: $f"
      cp -f "$f" "$DEST/"
      count=$((count + 1))
    done
    for f in "${DATA_FILES[@]}"; do if [[ -f $src/$f ]]; then cp -f "$src/$f" "$DEST/"; fi; done
    echo "Installed $count navmeshes into $DEST"
    ;;
  --build-from-client)
    die "--build-from-client is not available on macOS: the generator (tools/navmesh in the source) needs Windows/Wine automation. Rebuild with daoc server install."
    ;;
  *)
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
