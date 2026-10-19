# Upstream

Policy: **static snapshot, manual pulls.** See docs/ARCHITECTURE.md §9.

## Offline DAoC (direct parent)

- Upstream: https://github.com/shadowofze/OfflineDAoC (has git history and release tags).
- Our `src/` = upstream `source/server/` (`GameServer` with its `bots/` folder at `src/Bots`, `CoreBase`, `CoreDatabase`, `CoreServer`,
  `Pathing`, `Tests`, `sharedModules`) plus our own changes.
- Original fork point: upstream **`08ebffe`** (2026-10-01, between v0.33 and v0.34). Found by matching
  blobs: 3,214 of our 3,228 files were identical to it.
- **Synced to v0.35 / 0.35b "Claude Takeover III" (`d337d18`, 2026-10-08).** Applied
  `08ebffe..d337d18` for `source/server/{GameServer,CoreServer,Tests}` (our commit `5bf27bd`).
  Not imported: `source/server/tools/` (Windows client patchers and navmesh analysis scripts).
  - `CoreServer/Actions/ConsoleStart.cs`: kept ours. Upstream `c1c465c` (PR #3) backs off on stdin
    EOF; our console thread already stops reading at EOF.
- **Synced to v0.36 (`d88b7b2`, 2026-10-16).** v0.36, v0.36b and v0.36c are the same commit; the editions differ only in
  release packaging, which we don't import. Applied `d337d18..d88b7b2` for `source/server/{GameServer,CoreServer,CoreBase,
  CoreDatabase,Pathing,sharedModules,Tests}` with `git apply -p3 --directory=src` (clean, no conflicts). Includes the
  save-snapshot memory-leak fix (`CoreDatabase/DataObject.cs`, `UT_DataObjectSnapshot`), dead-pet cleanup, and the new
  autonomous bot logic (`bots/autonomous/AutonomousArmyPush`, `ZoneRoads`, ...). Not imported: client, launcher, release
  scripts and `tools/`. Sluaghbinder additions (`CripplingPlague`) came along because they are woven into shared enums;
  they stay off via `classes / enable_sluaghbinder = False`.
- **Synced to v0.37 (`ab4df02`, 2026-10-18).** v0.37, v0.37b and v0.37c are the same commit. Applied `d88b7b2..ab4df02`
  with `tools/upstream/sync.sh offlinedaoc apply v0.37` (its first real `apply`): every folder clean except one hunk in
  `src/Bots/autonomous/AutonomousPopulationController.cs` (the orphan-repair cache field, next to our population
  settings), applied by hand. Brings guild bots (`Bots/autonomous/AutonomousBotGuilds`, table `offline_world_bot_guild`),
  siege and raid fixes, bot travel and less route-search churn. After the sync, every mapped file is identical to
  upstream's except the ones listed below.
- Our own changes on top of upstream's files: `CoreServer/Actions/ConsoleStart.cs` (console host and
  `AdminHost.Register()`), `GameServer/packets/Client/168/LoginRequestHandler.cs` (the admin role hook and its lazy
  logger), `Bots/autonomous/AutonomousPopulationController.cs`, `AutonomousPopulationProperties.cs` and
  `AutonomousBotGoalPolicy.cs` (population settings and bot goals from the admin host), the `GameServer`, `CoreServer`
  and `Tests` csproj files, and `Pathing/Detour/CMakeLists.txt`. Our own folders: `Admin.Host/`, `DaocAdmin/`,
  `Admin.Protocol/`, `WorldBuilder/`.
- Next pull: `tools/upstream/sync.sh offlinedaoc report|check|apply <tag>` (docs/UPSTREAM-SYNC.md).
- The Sluaghbinder ("b" edition) code stays in, switched off by `classes / enable_sluaghbinder = False`,
  as upstream does for its plain edition.

## catastrophic-impact/daoc-offline-linux-server-bots (where this repo was forked from)

- Forked on 2026-10-18 at its `main` `18498ae` (Offline DAoC 0.36); `upstream-0.35` (`12a0846`) came along. Not
  synced since: take its changes, if any, as a merge or cherry-picks and note them here.

## World data and navmeshes

- Upstream ships its world DB and navmeshes only in its releases, never in git.
- **From 0.37 a release is an update to the 0.36 base** (`download-manifest.json` `"Mode": "patch"`): the full 0.36
  games stay on their release pages, and the v0.37b release carries `OfflineDAoC-v0.37-game-patch.zip` (38 MB) with
  the changed files and `db-0.37.json` / `db-0.37b.json` (identical in 0.37), which upstream's patcher
  (`source/tools/OfflineDaoc.Patcher`) applies to the player's database. No full 0.37 database exists, so
  `tools/world/apply-release-update.py` (a port of that patcher's `WorldUpdate`) makes the pristine one from 0.36's.
- **World: v0.37 (plain edition)** = the 0.36 plain DB (`OfflineDAoC-v0.36b/editions/0.36-no-custom-class/runtime/data/opendaoc.sqlite3.db`
  inside `OfflineDAoC-v0.36b.zip.001-.003`, SHA-256 `4fdb7ca4…`, read with `tools/world/rangezip.py`) plus
  `db-0.37.json`: 16 rows added, 263 changed, every changed row still as released (Mob, ItemTemplate, DataQuest,
  Path, PathPoints). The new `offline_world_bot_guild` table is player progress (the server creates it).
- `world/patches/200-*.sql` turn the OpenDAoC-Database dump (below) into that DB's world. They were regenerated with
  `tools/world/derive-world-delta.py` and verified to reproduce it exactly (0 differing tables). 0.37 adds
  `200-path.sql` and `200-pathpoints.sql`.
- `world/classic-quests.json` (0.37, from the game patch's `runtime/server/`) and `world/classic-quest-guides.json`
  (unchanged since 0.36, from the v0.36b zip's `runtime/server/`): the classic quests' step markers, event spawns,
  quest monsters and fellows (`GameServer/quests/QuestsMgr/ClassicQuests`) and the Quest Guide's pages (`QuestGuide`),
  both read next to the program. Earlier builds of this server ran without them: those quests had no markers or event
  spawns and the Quest Guide showed journal text only. The rest of the release's `runtime/server/` is binaries,
  configs this repo has its own of, translations (from `src/`), and `classic-otd.json`, which no server code reads.
- **Navmeshes: set `classic-si-4`** = `classic-si-3` (the v0.36b zip's `runtime/server/navmesh/`) with the 0.37 game
  patch's `pockets.json`, the only navmesh file 0.37 changes. Stored as one `.xz` per mesh in `world/navmesh/` so
  unchanged meshes cost nothing in later updates.
  - `classic-si-3` (0.36): the 103 `zone*.nav` files and `seams.json` are byte-identical to the 0.35 set
    (`classic-si-2`); `pockets.json` changed and `roads.json` is new (read by `Bots/autonomous/AutonomousZoneRoads`).
  - 0.35 reference: `OfflineDAoC-v0.35b.zip`, SHA-256 `5a1d77df…`, DB SHA-256 `feb4a511…`.

## OpenDAoC

- Upstream: https://github.com/OpenDAoC/OpenDAoC-Core. Offline DAoC is a fork of it with no recorded
  fork point. Compared with upstream `f0aaa1e` (2026-09-26): ~722 core files and ~50k lines differ,
  excluding `bots/`.
- Ported OpenDAoC fixes: none yet. Record each as `upstream <sha> -> our commit <sha>: why`.
- World data: https://github.com/OpenDAoC/OpenDAoC-Database, pinned at `98738ab8495f7e0a17412318e7c7c32a96d0eb09`
  (2026-09-29). A compressed copy is bundled in `world/upstream-db/` (with its GPL LICENSE);
  `tools/fetch-upstream-db.sh` unpacks it (or downloads, if it's missing) and checks a content hash
  over the `.sql` files. Moving the pin means re-running the delta script and re-verifying.
