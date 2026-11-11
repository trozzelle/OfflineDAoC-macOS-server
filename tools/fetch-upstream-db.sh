#!/usr/bin/env bash
# fetch-upstream-db.sh - provide the pinned OpenDAoC-Database dump in .cache/ and verify it.
# Uses the copy bundled in this repository (world/upstream-db/, no internet needed);
# downloads only if that is missing. Prints the path of the verified opendaoc-db-core folder.
#
#   tools/fetch-upstream-db.sh [--verbose]
#
#   --verbose   show download progress
# macOS port: uses shasum -a 256 (macOS has no sha256sum from coreutils).
set -euo pipefail

CURL_PROGRESS=-s
for arg in "$@"; do
  case $arg in
    -v|--verbose) CURL_PROGRESS=-# ;;
    -h|--help) echo "usage: fetch-upstream-db.sh [--verbose]"; exit 0 ;;
    *) echo "fetch-upstream-db: unknown argument: $arg (usage: fetch-upstream-db.sh [--verbose])" >&2; exit 2 ;;
  esac
done

# Pinned in the Linux repo's UPSTREAM.md. The commit ID pins the content (the codeload URL
# serves exactly that commit; the bundled tarball is per-file identical to it — verified).
# The Linux repo's DB_CONTENT_SHA256 (b7eac597...) does not reproduce against the pinned
# commit's files with the documented pipeline on any serialization tested (2026-10-08); it
# appears stale. The verification constant below is the pipeline value of the pinned commit
# itself, so it still detects corruption of the bundled/downloaded dump.
DB_COMMIT="98738ab8495f7e0a17412318e7c7c32a96d0eb09"
DB_CONTENT_SHA256="a6356e74dc74e008e24e3b1c18339207caa9ddd4d7a43fa00527084ed7bd91e6"
# shasum -a 256 of the bundled tarball in world/upstream-db/ (defense in depth for the offline path).
BUNDLED_SHA256="eb87141ffc756514226be05a9d752599c31e2f6d892d284e8983aba9bfb1914f"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CACHE="$HERE/.cache/opendaoc-db-$DB_COMMIT"
DUMP="$CACHE/opendaoc-db-core"

content_hash() { (cd "$1" && shasum -a 256 *.sql | sort -k2 | shasum -a 256 | cut -d' ' -f1); }

BUNDLED="$HERE/world/upstream-db/opendaoc-db-$DB_COMMIT.tar.xz"

if [[ ! -d $DUMP && -f $BUNDLED ]]; then
  actual_archive=$(shasum -a 256 "$BUNDLED" | cut -d' ' -f1)
  [[ $actual_archive == "$BUNDLED_SHA256" ]] || {
    echo "fetch-upstream-db: bundled archive checksum mismatch" >&2
    exit 1
  }
  mkdir -p "$CACHE"
  echo "Unpacking bundled OpenDAoC-Database $DB_COMMIT ..." >&2
  tar -xJf "$BUNDLED" -C "$CACHE"
fi
if [[ ! -d $DUMP ]]; then
  mkdir -p "$CACHE"
  echo "Downloading OpenDAoC-Database $DB_COMMIT ..." >&2
  curl -fSL "$CURL_PROGRESS" --retry 3 "https://codeload.github.com/OpenDAoC/OpenDAoC-Database/tar.gz/$DB_COMMIT" \
    | tar -xz -C "$CACHE" --strip-components=1 '*/opendaoc-db-core/*'
fi
actual=$(content_hash "$DUMP")
if [[ $actual != "$DB_CONTENT_SHA256" ]]; then
  echo "fetch-upstream-db: content hash mismatch for $DUMP" >&2
  echo "  expected $DB_CONTENT_SHA256" >&2
  echo "  actual   $actual" >&2
  echo "  Delete $CACHE and retry; if it persists, the pin in this script needs updating." >&2
  exit 1
fi
echo "$DUMP"