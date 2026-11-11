# Releasing and maintaining the data

## How a release is published

The `macos-build` workflow (`.github/workflows/macos-build.yml`) does it; nobody uploads by hand.

- **Triggers:** a push to `main` or to a version branch (`macos-<version>`), a pull request, or a manual run
  (`workflow_dispatch`).
- **Build:** on a `macos-latest` runner: the deploy-script tests (`python3 -m unittest discover -s
  tools/tests`), then `tools/build-release.sh`, then `tools/pack.sh`. A pull request stops here.
- **Publish:** on a push or manual run, a second job (the only one with `contents: write`) uploads
  the tarball and its `.sha256` to the GitHub release `macos-<game version>-<12-char commit>`,
  creating it if it is missing (not marked latest; the notes say it is a macOS build of that
  commit). If that release already has the tarball, the job uploads nothing and succeeds.
- **Never replaced:** a published asset is never deleted or overwritten. OfflineDAoC-macOS pins its
  SHA-256, so a rebuilt tarball of the same commit would break every install that pins it. A new
  build means a new commit, hence a new release.

The asset is `daoc-server-<game version>-<12-char commit>-osx-arm64.tar.xz` with a `.sha256` file.
Its layout and `.daoc-pin.json` are part of the interface with OfflineDAoC-macOS (see the README).

**Shipping a game version:** work for the next Offline DAoC version lands on `main`. When
OfflineDAoC-macOS ships it, cut `macos-<version>` from `main`; fixes for a shipped version go on
its branch, and each push there publishes a new release for that commit. OfflineDAoC-macOS then
pins the new commit and tarball.

To make the same tarball locally: `tools/build-release.sh` and then `tools/pack.sh` (see
[BUILD.md](BUILD.md)).

Never attach or commit a played database, logs, `serverconfig.xml` or `admins.json`.
`.gitignore` covers `dist/`, `build/`, `.cache/`, `*.db`, `*.sqlite`, `*.nav` and logs.

## Navmeshes

The repo carries one compressed file per mesh: `world/navmesh/zone042.nav.xz` and so on, plus
`seams.json.xz`, `pockets.json.xz` and `roads.json.xz`, listed with their SHA-256 in
`world/navmesh-manifest.sha256`. Git stores identical files once, so an Offline DAoC release that
changes 3 meshes adds about 20 MB to the repo, not a whole new archive. The current set is the 103
meshes plus the three bot data files (zone borders, walled pockets, roads) from Offline DAoC 0.37
(see `UPSTREAM.md`).

`tools/build-release.sh` installs them into the server folder with
`navmesh-install.sh --from-xz world/navmesh`, verifying every file against the manifest.

```bash
tools/navmesh-stage.sh <folder>       # folder of new meshes -> repo; only changed files are recompressed
```

**New meshes from an Offline DAoC release:** read them out of the release zip
(`tools/world/rangezip.py`, folder `runtime/server/navmesh/`), run `tools/navmesh-stage.sh <folder>`,
`git add world/navmesh world/navmesh-manifest.sha256`, build, retest the bots (their route data,
`Bots/autonomous/data/*.json`, was tuned on the current set). If the set is a new one, also change
its name in the manifest header and in `release.conf`.

## The world: upstream database pin and the Offline DAoC delta

- `tools/fetch-upstream-db.sh` pins OpenDAoC-Database (`DB_COMMIT`) and a content hash over its
  `.sql` files (`DB_CONTENT_SHA256`, independent of GitHub's archive compression).
- `world/patches/200-*.sql` are **generated**. Don't edit them by hand. They turn that upstream
  dump into the pristine world of the Offline DAoC release we track (0.37, plain edition).
- `world/patches/300-*.sql` are **hand-written** changes on top (for example
  `300-bot-login-speed.sql`). Add new world changes here, with a comment explaining why.

**Moving the upstream DB pin, or moving to a new Offline DAoC release** (rare and deliberate; for
a new release, skip step 1):
1. Set `DB_COMMIT` in `fetch-upstream-db.sh`, delete `.cache/`, move the old
   `world/upstream-db/*.tar.xz` away (otherwise it is used), run the script once (it downloads),
   and set `DB_CONTENT_SHA256` to the hash it prints in the mismatch message. Then bundle the new
   dump:
   `tar -C .cache/opendaoc-db-<commit> -cf - opendaoc-db-core | xz -9 > world/upstream-db/opendaoc-db-<commit>.tar.xz`
2. Build the plain upstream world (no patches):
   `dotnet src/WorldBuilder/bin/Release/net10.0/DaocWorldBuilder.dll --source <dump> --out /tmp/upstream.sqlite`
3. Regenerate the delta. You need the release's pristine plain-edition world DB:
   `editions/<version>-no-custom-class/runtime/data/opendaoc.sqlite3.db` inside the "b" release zip
   (for 0.36: SHA-256 `4fdb7ca4…`, also listed in the plain release's `download-manifest.json`).
   The zip is split in parts, so read the one file with HTTP range requests rather than downloading
   it all (see `tools/world/rangezip.py`).
   From 0.37 a release is an update to the 0.36 base (`"Mode": "patch"` in its
   `download-manifest.json`) and ships no database: take the 0.36 plain DB above and apply the game
   patch's (`OfflineDAoC-v<x>-game-patch.zip` on the v<x>b release) `db-<x>.json` to it with
   `python3 tools/world/apply-release-update.py <db> db-<x>.json`. Its counts must match the JSON's
   `Summary`, with no rows "left as the game had them".
   Set `WORLD` at the top of the script to the release, then
   `python3 tools/world/derive-world-delta.py <pristine db> /tmp/upstream.sqlite world/patches`
   (it removes nothing itself: delete the old `200-*` files first). Check the script's `EXCLUDED`
   list against the release's `progress-policy.json` (in its `OfflineDaoc.ProgressImport` source).
4. Verify: build with only the `200-*` patches (`--patches <folder with copies of them>`), then
   run the same script against the result. It must print `0 tables differ`.
5. Update `UPSTREAM.md`.

## Upgrading OpenDAoC itself

This code base is a heavily modified fork (about 720 upstream files changed). Upgrading means
merging. It's a project of its own, not a routine step; see `UPSTREAM.md`. Port individual
upstream fixes by hand and cite the upstream commit.
