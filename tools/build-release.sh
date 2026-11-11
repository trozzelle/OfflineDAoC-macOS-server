#!/usr/bin/env bash
# build-release.sh - build the portable macOS server folder.
#
#   tools/build-release.sh [--verbose] -> dist/daoc-server/ (or $DAOC_SERVER_OUT)
#
#   --verbose   show compiler/MSBuild warnings, cmake and WorldBuilder output, and
#               database download progress
#
# Needs the .NET 10 SDK (tools/setup-dotnet.sh installs it), cmake, clang (Xcode Command Line Tools)
# and curl. The result needs none of them: it bundles the .NET runtime and contains a fresh
# Classic + SI world built from the pinned upstream OpenDAoC-Database plus world/patches.
# Navmeshes come from world/navmesh (installed into the folder); no client files are included.
#
# Notes:
#   - RID is osx-arm64 (Apple Silicon).
#   - The native pathing library builds as libDetour.dylib and ships as bin/lib/Detour.dylib.
#     .NET probes "lib/Detour" as "lib/Detour.dylib" on macOS.
#   - Codesigning: the bundled .NET runtime and the Detour library are ad-hoc signed at build
#     time so Gatekeeper quarantine and hardened-runtime checks do not block execution.
set -euo pipefail

VERBOSE=
for arg in "$@"; do
  case $arg in
    -v|--verbose) VERBOSE=1 ;;
    -h|--help) echo "usage: build-release.sh [--verbose]"; exit 0 ;;
    *) echo "build-release: unknown argument: $arg (usage: build-release.sh [--verbose])" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"                           # the repository root
# Where the vendored System.Data.SQLite source lives (see vendor/README.md).
SDS_SRC="${SDS_SRC:-$HERE/vendor/System.Data.SQLite}"
SDS_PROJ="$SDS_SRC/System.Data.SQLite.NetStandard21.csproj"
DOTNET="${DOTNET:-${DOTNET_ROOT:-$HOME/.dotnet}/dotnet}"
[[ -x $DOTNET ]] || DOTNET="${DOTNET:-$(command -v dotnet || true)}"
# The Offline DAoC game version this checkout implements: DAOC_GAME_VERSION, else the
# OfflineDaocVersion constant in AdminService.cs (src/Admin.Host/ or src/GameServer/admin/,
# depending on the version). Its Sluaghbinder overlay lives in world/editions/<version>/.
GAME_VERSION="${DAOC_GAME_VERSION:-}"
if [[ -z $GAME_VERSION ]]; then
  while IFS= read -r f; do
    GAME_VERSION="$(sed -n 's/.*OfflineDaocVersion *= *"\([^"]*\)".*/\1/p' "$f" | sed -n 1p)"
    [[ -z $GAME_VERSION ]] || break
  done < <(find "$HERE/src" -maxdepth 3 -name AdminService.cs -not -path '*/obj/*' -not -path '*/bin/*' 2>/dev/null | sort)
fi
[[ -n $GAME_VERSION ]] || { echo "build-release: no OfflineDaocVersion = \"<version>\" constant found in any src/**/AdminService.cs (set DAOC_GAME_VERSION)" >&2; exit 1; }
# <game version>-<12-char commit>, plus -dirty when tracked files have uncommitted changes.
COMMIT="$(git -C "$HERE" rev-parse --short=12 HEAD 2>/dev/null)" ||
  { echo "build-release: $HERE is not a git checkout with a commit" >&2; exit 1; }
VERSION="$GAME_VERSION-$COMMIT"
[[ -z $(git -C "$HERE" status --porcelain --untracked-files=no) ]] || VERSION="$VERSION-dirty"
# The install folder: `daoc server install` sets DAOC_SERVER_OUT to its data home's server folder.
OUT="${DAOC_SERVER_OUT:-$HERE/dist/daoc-server}"
[[ -f $HERE/world/editions/$GAME_VERSION/sluaghbinder.sql ]] ||
  { echo "build-release: no world/editions/$GAME_VERSION/sluaghbinder.sql" >&2; exit 1; }
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

# Build steps print errors only, unless --verbose. `dotnet build` appends its own
# -consoleloggerparameters:Summary, which MSBuild merges with ours (a "N Warning(s)" block on
# every run), so builds go through `dotnet msbuild -restore` (what `dotnet build` wraps) instead.
# Tools without an errors-only mode run via quiet(): silent on success, full output on failure.
MSB_LOG=(-v:quiet -clp:ErrorsOnly)
# Only the WorldBuilder's result lines, unless --verbose (empty pattern: every line).
WORLD_LINES='^(Schema|World)'
if [[ -n $VERBOSE ]]; then
  MSB_LOG=(-v:minimal -clp:Summary)   # every warning as it happens, recapped at the end
  WORLD_LINES=''
fi
quiet() {
  [[ -z $VERBOSE ]] || { "$@"; return; }
  local log rc=0; log=$(mktemp)
  "$@" >"$log" 2>&1 || rc=$?
  ((rc == 0)) || cat "$log" >&2
  rm -f "$log"
  return $rc
}

missing=()
"$DOTNET" --list-sdks 2>/dev/null | grep -q '^10\.' || missing+=(".NET 10 SDK (install: curl -fsSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 10.0)")
command -v cmake >/dev/null || missing+=("cmake (brew install cmake)")
command -v clang++ >/dev/null || missing+=("clang (Xcode Command Line Tools: xcode-select --install)")
command -v curl >/dev/null || missing+=("curl")
if ((${#missing[@]})); then
  echo "build-release: missing: ${missing[*]}" >&2
  echo "  See README.md for setup instructions." >&2
  exit 1
fi

# Build from a snapshot of src/ so build outputs never land in the checkout. Only source projects
# are copied (no build outputs); SNAPSHOT is reused between runs (rsync-style refresh) to keep
# rebuilds fast. It lives under build/, which is gitignored.
SNAPSHOT="$HERE/build/src"
mkdir -p "$SNAPSHOT"
echo "== Syncing source snapshot from $HERE/src"
rsync -a --delete \
  --exclude='.git' \
  --exclude='Release/' --exclude='build/' --exclude='bin/' --exclude='obj/' \
  "$HERE/src/" "$SNAPSHOT/"
# The WorldBuilder needs a config dir for its serverconfig (the build only needs it to exist).
[[ -f $SNAPSHOT/CoreServer/config/serverconfig.xml ]] ||
  cp "$SNAPSHOT/CoreServer/config/serverconfig.example.xml" "$SNAPSHOT/CoreServer/config/serverconfig.xml"

# Never replace bin/ under a live server.
if [[ -x $OUT/daoc-server.sh ]] && DAOC_HOME="$OUT" "$OUT/daoc-server.sh" status | grep -q '^running'; then
  echo "build-release: the server in $OUT is running; stop it first (./daoc-server.sh stop)" >&2
  exit 1
fi
# The folder is also the user's install: replace only what the build owns (bin/, defaults/ and
# the top-level EXTRAS). config/, data/ (accounts, characters, bots), logs/ and run/ are the
# user's and survive every rebuild; navmesh/ is refreshed in place by the navmesh step below.
EXTRAS=(daoc-server.sh admin-socket.sh daoc-admin daoc-progress navmesh-install.sh release.conf README.md VERSION)
rm -rf "$OUT/bin" "$OUT/defaults" "${EXTRAS[@]/#/$OUT/}"
echo "== Publishing server (self-contained osx-arm64)"
"$DOTNET" publish "$SNAPSHOT/CoreServer/CoreServer.csproj" -c Release -r osx-arm64 --self-contained true \
  -o "$OUT/bin" -nologo "${MSB_LOG[@]}"

# daoc-admin shares bin/ (and its bundled runtime) with the server.
echo "== Publishing daoc-admin (TUI + CLI)"
"$DOTNET" publish "$SNAPSHOT/DaocAdmin/DaocAdmin.csproj" -c Release -r osx-arm64 --self-contained true \
  -o "$OUT/bin" -nologo "${MSB_LOG[@]}"

# daoc-progress (port addition: upstream's progress importer for world upgrades) shares bin/ too.
# It references the vendored System.Data.SQLite project directly, so it never binds SQLite.Interop.
echo "== Publishing daoc-progress (world upgrade / progress import)"
"$DOTNET" publish "$HERE/tools/ProgressImport/ProgressImport.csproj" -c Release -r osx-arm64 --self-contained true \
  -o "$OUT/bin" -nologo "${MSB_LOG[@]}"

echo "== Building native pathing library"
quiet cmake -S "$SNAPSHOT/Pathing/Detour" -B "$HERE/build/detour" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64
quiet cmake --build "$HERE/build/detour"
mkdir -p "$OUT/bin/lib"
# LibraryImport("lib/Detour") probes lib/Detour.dylib on macOS (lib/Detour.so on Linux).
cp -L "$HERE/build/detour/libDetour.dylib" "$OUT/bin/lib/Detour.dylib"
# Ad-hoc signature: the shared library was built by a different toolchain than the .NET runtime;
# keep every Mach-O in the folder validly signed so execution is never blocked.
codesign --force --sign - "$OUT/bin/lib/Detour.dylib" >/dev/null 2>&1 || true

# A post-build step copies translations into src/Release/ only; publish needs them too.
# (BSD install has no -D; rsync preserves the relative layout instead.)
mkdir -p "$OUT/bin/languages"
rsync -a --include='*/' --include='*.txt' --exclude='*' "$SNAPSHOT/GameServer/language/" "$OUT/bin/languages/" >/dev/null 2>&1 || \
  (cd "$SNAPSHOT/GameServer/language" && find . -type d -exec mkdir -p "$OUT/bin/languages/{}" \; && find . -name '*.txt' -exec cp {} "$OUT/bin/languages/{}" \;)

# System.Data.SQLite 1.0.119 ships prebuilt native SQLite.Interop binaries for win-x86/x64,
# linux-x64 and osx-x64 only — there is no osx-arm64 build, and its interop exports hashed
# symbol names. The project source (same version) compiled with SQLITE_STANDARD binds the
# plain system libsqlite3 ("sqlite3") with plain entry names, which macOS ships. Build the
# managed assembly from the vendored source and use it instead of the NuGet package's copy.
echo "== Building System.Data.SQLite (SQLITE_STANDARD: uses the macOS system libsqlite3)"
if [[ ! -f $SDS_PROJ ]]; then
  echo "build-release: missing $SDS_PROJ — see vendor/README.md for how to vendor it" >&2
  exit 1
fi
"$DOTNET" msbuild "$SDS_PROJ" -restore -p:NuGetInteractive=false -p:Configuration=Release -p:UseInteropDll=false -p:UseSqliteStandard=true \
  -p:SignAssembly=false -p:PublicSign=false -p:DelaySign=false -nologo "${MSB_LOG[@]}"
sds_dll="$SDS_SRC/obj/Release/netstandard2.1/System.Data.SQLite.dll"
[[ -f $sds_dll ]] || { echo "build-release: System.Data.SQLite build produced no output" >&2; exit 1; }
# Overlay it onto every output that carries the NuGet stub's interop-variant dll: the server
# publish output and the WorldBuilder build output (WorldBuilder links CoreDatabase too, and
# it must bind the system libsqlite3 the same way when it builds the world database).
echo "== Building the world (upstream OpenDAoC-Database + world/patches)"
dump=$("$HERE/tools/fetch-upstream-db.sh" ${VERBOSE:+--verbose})
"$DOTNET" msbuild "$SNAPSHOT/WorldBuilder/WorldBuilder.csproj" -restore -p:NuGetInteractive=false -p:Configuration=Release -nologo "${MSB_LOG[@]}"
# Overlay it onto every output that carries the NuGet stub's interop-variant dll: the server
# publish output and the WorldBuilder build output (WorldBuilder links CoreDatabase too and
# must bind the system libsqlite3 the same way). This runs AFTER the WorldBuilder build so
# the restore process cannot put the stub's variant back.
for out_dir in "$OUT/bin" "$SNAPSHOT/WorldBuilder/bin/Release/net10.0"; do
  [[ -d $out_dir ]] || continue
  cp "$sds_dll" "$out_dir/System.Data.SQLite.dll"
  # The stub's native runtimes are not needed (and osx-arm64 does not exist); drop them so
  # nothing probes SQLite.Interop.dll.
  rm -rf "$out_dir/runtimes"
done
mkdir -p "$OUT/defaults"
"$DOTNET" "$SNAPSHOT/WorldBuilder/bin/Release/net10.0/DaocWorldBuilder.dll" \
  --source "$dump" --out "$OUT/defaults/world.sqlite" --patches "$HERE/world/patches" | grep -E "$WORLD_LINES"

# The Sluaghbinder Edition's world: the Classic world above plus upstream's Edition rows
# (world/editions/<version>/sluaghbinder.sql). A statement that fails (e.g. a key this
# repository's world already uses) fails the build: that world diverged.
echo "== Sluaghbinder world (world/editions/$GAME_VERSION)"
overlay="$HERE/world/editions/$GAME_VERSION/sluaghbinder.sql"
sluagh="$OUT/defaults/world-sluaghbinder.sqlite"
cp "$OUT/defaults/world.sqlite" "$sluagh"
sqlite3 -bail "$sluagh" < "$overlay" || { echo "build-release: $overlay does not apply to this world" >&2; exit 1; }
[[ $(sqlite3 "$sluagh" "SELECT Value FROM ServerProperty WHERE \"Key\"='enable_sluaghbinder'") == True ]] ||
  { echo "build-release: $overlay left enable_sluaghbinder off" >&2; exit 1; }

# The server reads config/ next to its program and navmesh/ from its working directory (bin/).
rm -rf "$OUT/bin/config"
ln -s ../config "$OUT/bin/config"
ln -s ../navmesh "$OUT/bin/navmesh"
ln -s ../logs "$OUT/bin/logs"

cp "$HERE/deploy/serverconfig.template.xml" "$OUT/defaults/serverconfig.xml"
cp "$SNAPSHOT/GameServer/config/logconfig.xml" "$SNAPSHOT/GameServer/config/invalidnames.txt" "$OUT/defaults/"
# The classic quests' data, which the server reads next to the program: classic-quests.json (step
# markers, event spawns, quest monsters; ClassicQuests) and classic-quest-guides.json (the Quest
# Guide's pages; QuestGuide). Without them those are off.
for f in classic-quests.json classic-quest-guides.json; do
  if [[ -f $HERE/world/$f ]]; then cp "$HERE/world/$f" "$OUT/bin/"; fi
done
cp "$HERE/deploy/daoc-server.sh" "$HERE/deploy/admin-socket.sh" "$HERE/deploy/daoc-admin" "$HERE/deploy/daoc-progress" "$HERE/deploy/navmesh-install.sh" \
  "$HERE/deploy/release.conf" "$OUT/"
cp "$HERE/deploy/README-release.md" "$OUT/README.md"
echo "$VERSION" > "$OUT/VERSION"

# Ad-hoc-sign every Mach-O the dotnet publish step laid down; quarantine/hardened-runtime checks
# then behave like on Linux (nothing to approve, nothing to bypass).
echo "== Ad-hoc codesigning"
find "$OUT/bin" -type f \( -perm -111 -o -name '*.dylib' \) -print0 | while IFS= read -r -d '' f; do
  file "$f" | grep -q Mach-O && codesign --force --sign - "$f" >/dev/null 2>&1 || true
done

# Navmeshes come from this repository's world/navmesh/ (one .xz per mesh plus navmesh-manifest.sha256).
# Verify them and install them into the folder so dist/daoc-server is ready to start.
echo "== Navmeshes (world/navmesh)"
DAOC_HOME="$OUT" "$OUT/navmesh-install.sh" --from-xz "$HERE/world/navmesh"

echo "== Done: $OUT ($VERSION)"