# DAoC server: start here (AI assistants and developers)

This file is loaded by Claude Code as `CLAUDE.md`. Read it fully before changing anything, then the
doc for your task:

| Task | Read |
|---|---|
| Anything about bots | [docs/BOTS-DEV.md](docs/BOTS-DEV.md): kinds, lifecycle, code map, dev loop, plan |
| How the system fits together | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Building and testing | [docs/BUILD.md](docs/BUILD.md) |
| Running, admin, upgrades, troubleshooting | [docs/RUN.md](docs/RUN.md) |
| Releases, navmesh set, world data, DB pin | [docs/RELEASING.md](docs/RELEASING.md) |
| Upstream pins | [UPSTREAM.md](UPSTREAM.md) |
| Why things are the way they are | [docs/history/](docs/history/) |

## What this is

A **Dark Age of Camelot server** for macOS on Apple Silicon (OpenDAoC fork, .NET 10, SQLite) with
**autonomous gamebots** and **companion bots**. It's released as one portable folder with a
built-in Classic + Shrouded Isles world and its navmeshes. The game client is
not part of the project. The owner's goal now is to **develop the bots**: smarter, natural
behaviour, dungeons, battlegrounds, keeps and frontier, and later chat.

## Folders

This repo is a clone of github.com/trozzelle/OfflineDAoC-macOS-server; all work happens here.
Build output goes to `dist/` and `build/` (both gitignored); the .NET SDK is in `~/.dotnet`.

Upstream is https://github.com/shadowofze/OfflineDAoC (see `UPSTREAM.md`); clone it to a scratch
folder when you need to compare or pull. Its release zips hold the world DB and navmeshes.
`rewrite/` and the old `project/` Linux build are gone; see `docs/history/`.

## Environment and how to run things

- **Host:** an Apple Silicon Mac with the Xcode Command Line Tools and cmake. If the .NET 10 SDK is
  missing, run `tools/setup-dotnet.sh` (safe to re-run).
- **Healthy startup logs ~390 ERR.** It is upstream's own data; watch for changes, not the number.
- **Common commands** (from the repo root):
  - Build and test: `cd src && ~/.dotnet/dotnet build DaocServer.sln -c Release && ~/.dotnet/dotnet test Tests/Tests.csproj -c Release --no-build`
  - Deploy-script tests: `python3 -m unittest discover -s tools/tests`
  - Full release: `tools/build-release.sh`. About 2 minutes; creates `dist/daoc-server`.
    `tools/pack.sh` then packs it as the release tarball.
  - Test server: copy `dist/daoc-server` to `~/test/daoc-server`, then
    `tools/dev-deploy.sh ~/test/daoc-server` for quick code updates (about 15 s).
  - Run it: `<folder>/daoc-server.sh start` (or `start --console`); admin:
    `<folder>/daoc-admin bots list` and so on.
- **Ports:** game TCP 10300, UDP 10400. Only one server at a time. Check with
  `lsof -nP -iTCP:10300` before starting.
- **The interface with OfflineDAoC-macOS** (folder layout, script flags, `daoc-admin --json`, the
  admin socket rule, the tarball and `.daoc-pin.json`) is described in the README; changing it
  needs a matching change there.

## Gotchas

- **CRLF:** many source files use CRLF line endings. Preserve them when editing (check with
  `file`). Don't rewrite whole files with a different ending.
- **The build needs `src/CoreServer/config/serverconfig.xml`** to exist (it's gitignored). Copy it
  from `serverconfig.example.xml`; the scripts do this.
- **Server root is `bin/`:** `bin/config`, `bin/navmesh` and `bin/logs` are symlinks to the
  folder's own directories.
- **Bots are NPCs pretending to be players** (`GameBot : GameNPC, IGamePlayer`). Core files
  special-case them, so bot changes can touch `GameNPC`, `SpellHandler` and other core files.
- **Navmeshes are in the source** as one `world/navmesh/<file>.xz` per mesh (git stores unchanged
  meshes once, so an upstream update adds only the meshes that changed). `build-release.sh` unpacks,
  verifies and installs them into `dist/daoc-server`. New meshes: `tools/navmesh-stage.sh`.
  Rebuilding replaces `dist/`; play on a copy elsewhere.
- **`world/patches/200-*.sql` are generated.** Never hand-edit them; add `300-*` files instead
  (docs/RELEASING.md).
- **Don't trust "it compiles":** check bot behaviour on the dev server (TUI Bots tab, `/tele`,
  `logs/server.log`).
- **`/travel` doesn't work on macOS** (it drives the Windows client's keyboard). `&tc` is
  registered twice. Both are known issues (docs/ARCHITECTURE.md §8).

## Rules

- **Protect player data.** Never commit a played database, logs, backups, credentials,
  `serverconfig.xml` or `admins.json`. `.gitignore` is a safety net only.
- **Keep the owner's gameplay rules:**
  - real loot, inventories, coins and equipment upgrades;
  - the Realm Exchange;
  - stablemaster routes;
  - selling only at natural task breaks;
  - gamebots start without armor and earn it;
  - Darkness Falls is open to solo bots.
- **Tell bot types apart:** real players, companion bots and autonomous gamebots are different.
- **No unbounded loops in bot code.** Every loop, retry and search has an explicit cap.
- **No client assumptions in `src/`:** no `game.dll`, client paths or input injection (the
  `/travel` legacy is a known exception to remove).
- **Don't start a server, or deploy over a running one, without the owner's OK.** The owner often
  has a server running on 10300.
- **Be honest in reports:** automated tests and in-game checks are separate claims. Don't
  describe Darkness Falls raid AI, Legion or the hardest level 70+ content as implemented.
- **Upstream is a static snapshot:** port fixes by hand and cite the upstream commit.
- **Communication:** the owner prefers short, direct answers and is careful with token cost. Do
  the work, report briefly, and don't start large explorations without saying why.
