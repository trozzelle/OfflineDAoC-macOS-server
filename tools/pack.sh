#!/usr/bin/env bash
# pack.sh - pack the built server folder as one release tarball.
#
#   tools/pack.sh [OUT_DIR]     default OUT_DIR: dist/ in the repository
#
# Packs $DAOC_SERVER_OUT (default dist/daoc-server, from tools/build-release.sh) as
#   <OUT_DIR>/daoc-server-<game version>-<12-char commit>-osx-arm64.tar.xz
# with the root folder daoc-server/, and writes <tarball>.sha256 beside it (shasum -a 256 format).
# config/, data/, logs/ and run/ are the user's and are never packed. The archive also carries
# daoc-server/.daoc-pin.json: the full commit this build came from, which `daoc server install` and
# `daoc server update` read. Refuses a tree with uncommitted changes, and a folder that was built
# from another commit than HEAD. Prints the tarball path last.
set -euo pipefail

die() { echo "pack: $*" >&2; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SERVER="${DAOC_SERVER_OUT:-$REPO/dist/daoc-server}"
OUT_DIR="${1:-$REPO/dist}"
UPSTREAM_URL="https://github.com/trozzelle/OfflineDAoC-macOS-server"
ROOT_NAME=daoc-server

[[ -z $(git -C "$REPO" status --porcelain --untracked-files=no) ]] ||
  die "the working tree has uncommitted changes; commit or stash them, then run tools/build-release.sh again"
command -v xz >/dev/null || die "xz is missing (brew install xz)"
[[ -f $SERVER/VERSION && -x $SERVER/bin/CoreServer ]] ||
  die "no built server folder at $SERVER (run tools/build-release.sh first)"

SHA="$(git -C "$REPO" rev-parse HEAD)"
COMMIT="$(git -C "$REPO" rev-parse --short=12 HEAD)"
VERSION="$(<"$SERVER/VERSION")"
# VERSION is <game version>-<12-char commit> (build-release.sh); "-dirty" means a build from edited files.
[[ $VERSION == *-"$COMMIT" ]] ||
  die "$SERVER is version $VERSION, not a build of $COMMIT; run tools/build-release.sh again"
GAME_VERSION="${VERSION%-"$COMMIT"}"
[[ -n $GAME_VERSION ]] || die "$SERVER/VERSION has no game version"

BRANCH="$(git -C "$REPO" symbolic-ref --short -q HEAD || true)"
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"
TARBALL="$OUT_DIR/daoc-server-$GAME_VERSION-$COMMIT-osx-arm64.tar.xz"

# The record goes into the folder only while tar runs.
PIN="$SERVER/.daoc-pin.json"
PARTIAL="$TARBALL.partial"
cleanup() { rm -f "$PIN" "$PARTIAL"; }
trap cleanup EXIT
printf '{"upstream": "%s", "ref": "%s", "branch": "%s"}\n' \
  "$UPSTREAM_URL" "$SHA" "$(json_escape "$BRANCH")" > "$PIN"

# Entries are listed explicitly (not the folder itself) so the user's folders are left out by
# construction, and -s puts every path (and hard-link target, but not symlink target, hence the S flag: bin/config
# is a relative link) under daoc-server/ whatever the folder is called.
entries=()
while IFS= read -r name; do
  case $name in
    config|data|logs|run) ;;
    *) entries+=("$name") ;;
  esac
done < <(cd "$SERVER" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | LC_ALL=C sort)

echo "== Packing $SERVER as $(basename "$TARBALL")"
# System bsdtar into a multithreaded xz (bsdtar's own xz filter, even with --options xz:threads=0,
# compresses on one thread: about 14 minutes instead of about one). COPYFILE_DISABLE and
# --no-mac-metadata keep AppleDouble (._*) files and extended attributes out; owner fields are
# neutral so no local user name ships. pipefail (above) fails the pack if either side fails.
COPYFILE_DISABLE=1 /usr/bin/tar --no-mac-metadata --uid 0 --gid 0 --uname root --gname wheel \
  -s "|^|$ROOT_NAME/|S" -cf - -C "$SERVER" "${entries[@]}" | xz -T0 -6 -c > "$PARTIAL"
mv -f "$PARTIAL" "$TARBALL"

(cd "$OUT_DIR" && shasum -a 256 "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256")
echo "== sha256: $(cut -d' ' -f1 "$TARBALL.sha256")"
echo "$TARBALL"
