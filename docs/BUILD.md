# Building

The build produces a portable server folder for Apple Silicon Macs (osx-arm64) that needs no .NET
install. To run it, see [RUN.md](RUN.md); to publish it, see [RELEASING.md](RELEASING.md).

```
dist/daoc-server/                                          portable server folder, ready to start (world and navmeshes installed)
dist/daoc-server-<game version>-<commit>-osx-arm64.tar.xz  the folder as one archive (tools/pack.sh; about 450 MB)
dist/daoc-server-<...>.tar.xz.sha256                       its checksum
```

No client files are included.

## What you need

- An Apple Silicon Mac with the Xcode Command Line Tools (`xcode-select --install`: clang, git,
  `tar`, `codesign`).
- `cmake` and `xz` (`brew install cmake xz`) and curl.
- The .NET 10 SDK: `tools/setup-dotnet.sh` installs it into `~/.dotnet` (no sudo; safe to re-run).
  The build also finds `dotnet` on `PATH`, or `DOTNET=...`.
- About 5 GB of free disk space, and internet access on the first build.

## What `tools/build-release.sh` does

It builds into `dist/daoc-server/`, or into `$DAOC_SERVER_OUT` when that is set (that is how
OfflineDAoC-macOS builds into its install folder). A rebuild replaces only what the build owns
(`bin/`, `defaults/` and the top-level scripts); `config/`, `data/`, `logs/` and `run/` stay. It
refuses to run while the server in that folder is running.

1. `dotnet publish` of `CoreServer` (the server), `DaocAdmin` (the TUI/CLI) and `daoc-progress`
   (the world upgrade importer), self-contained for osx-arm64, into `bin/`.
2. Builds `src/Pathing/Detour` with CMake into `bin/lib/Detour.dylib`.
3. Builds the vendored System.Data.SQLite ([vendor/README.md](../vendor/README.md)) so the server
   binds the system `libsqlite3`, and overlays it onto the outputs.
4. **World:**
   - `tools/fetch-upstream-db.sh` unpacks the pinned OpenDAoC-Database bundled in
     `world/upstream-db/` (it downloads only if the bundle is missing) into `.cache/` and
     verifies its content hash;
   - `src/WorldBuilder` creates the schema from the server's own DataObjects, loads the dump and
     applies `world/patches/*.sql`;
   - the result is `defaults/world.sqlite`, plus `defaults/world-sluaghbinder.sqlite` (the same
     world with `world/editions/<game version>/sluaghbinder.sql` applied).
5. Copies translations, default config, the quest data, the scripts (`daoc-server.sh`,
   `admin-socket.sh`, `daoc-admin`, `daoc-progress`, `navmesh-install.sh`, `release.conf`) and the
   README into the folder.
6. Ad-hoc codesigns every Mach-O in `bin/`, so Gatekeeper and hardened-runtime checks do not block
   the bundled runtime or the Detour library.
7. **Navmeshes:** `navmesh-install.sh --from-xz world/navmesh` decompresses the meshes, verifies
   every file against `world/navmesh-manifest.sha256`, and installs them into `navmesh/`.
8. Writes `VERSION`: `<game version>-<12-char commit>` (`-dirty` when tracked files have
   uncommitted changes). The game version is the `OfflineDaocVersion` constant in
   `AdminService.cs`; set `DAOC_GAME_VERSION` to override it.

It takes about 1.5 to 3 minutes. For bot and server code changes, use the much faster
`tools/dev-deploy.sh` instead (see [BOTS-DEV.md](BOTS-DEV.md)).

## Packing

```bash
tools/pack.sh [OUT_DIR]        # default dist/
```

Packs `dist/daoc-server` (or `$DAOC_SERVER_OUT`) as
`daoc-server-<game version>-<12-char commit>-osx-arm64.tar.xz` with the root folder `daoc-server/`
(system `tar` into multithreaded `xz`, about a minute), writes `.daoc-pin.json` into the archive (the
full commit, for OfflineDAoC-macOS) and the `.sha256` file, and prints the tarball path. It leaves
out `config/`, `data/`, `logs/` and `run/`, and refuses a tree with uncommitted changes or a folder
that was built from another commit than `HEAD`: build again first.

## Tests

The deploy scripts (`daoc-server.sh`, `admin-socket.sh`, `daoc-admin`) have stdlib-only tests that
run them against a fake server:

```bash
python3 -m unittest discover -s tools/tests
```

## Build and test only

```bash
cd src
cp -n CoreServer/config/serverconfig.example.xml CoreServer/config/serverconfig.xml  # local, gitignored
dotnet build DaocServer.sln -c Release
dotnet test Tests/Tests.csproj -c Release --no-build
```

With the SDK from `tools/setup-dotnet.sh`, use `~/.dotnet/dotnet`. Build outputs go to `src/Release/` (server DLLs in
`src/Release/lib/`) and `src/build/`. 47 tests that need an installed world are skipped unless
`OFFLINE_DAOC_NAV_ROOT`, `OFFLINE_DAOC_DB_PATH` and `OFFLINE_DAOC_TEST_DETOUR` are set.
