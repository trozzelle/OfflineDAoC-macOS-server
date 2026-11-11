# OfflineDAoC-macOS server

The DAoC server that [OfflineDAoC-macOS](https://github.com/trozzelle/OfflineDAoC-macOS) builds
and runs on macOS: [Offline DAoC](https://github.com/shadowofze/OfflineDAoC)'s OpenDAoC server
with its autonomous and companion bots (synced to 0.37), plus an admin host and TUI, a world
builder, and the Offline DAoC world data and navmeshes. `daoc server install` installs it from
a prebuilt tarball published here, or builds it into one folder with `tools/build-release.sh`.

## Where it comes from

- Forked on 2026-10-18 from catastrophic-impact's
  [daoc-offline-linux-server-bots](https://github.com/catastrophic-impact/daoc-offline-linux-server-bots)
  (main at `18498ae`, Offline DAoC 0.36), a Linux build of the same server. Its
  history and branches are kept here; `upstream-0.35` holds the 0.35 line.
- Offline DAoC is tracked directly: `tools/upstream/sync.sh offlinedaoc …` pulls each release's
  server code ([docs/UPSTREAM-SYNC.md](docs/UPSTREAM-SYNC.md), [UPSTREAM.md](UPSTREAM.md)).
- Our own changes are commits on top: macOS fixes and, from here on, our features and macOS
  performance work. Each game version OfflineDAoC-macOS ships has a `macos-<version>` branch
  (`macos-0.35`, `macos-0.36`, `macos-0.37`), which that version's pin and `daoc server update`
  follow. `main` is where the next Offline DAoC sync lands; its version's branch is cut from it
  when OfflineDAoC-macOS ships that version. Fixes for a shipped version go on its branch.

## Build it on macOS

**What you need:** an Apple Silicon Mac, the Xcode Command Line Tools (`xcode-select --install`),
`cmake` and `xz` (`brew install cmake xz`), curl, and the .NET 10 SDK, which `tools/setup-dotnet.sh` installs
into `~/.dotnet`. About 5 GB of free disk space and internet for the first build. The world and
the navmeshes are in the source (`world/navmesh/`, one compressed file per mesh, about 360 MB).

```bash
git clone https://github.com/trozzelle/OfflineDAoC-macOS-server.git
cd OfflineDAoC-macOS-server
tools/setup-dotnet.sh        # once
tools/build-release.sh       # about 1.5-3 minutes
```

The result is `dist/daoc-server/`: the server with its bundled .NET runtime, the world and the
navmeshes, ready to start. It needs no .NET on the machine that runs it. `tools/build-release.sh`
builds into `$DAOC_SERVER_OUT` when that is set.

```bash
cd dist/daoc-server
./daoc-server.sh start
```

The server starts in the background and an admin screen opens in the same terminal:

| Tab | What you can do |
|---|---|
| **Server** | Status, live log, **Stop server** |
| **Bots** | See every bot and what it is doing; **create** real bots (realm, level 1 or 50, class, count); **delete** |
| **Population** | Turn bots on/off; set the most bots in the world at once |
| **Accounts** | Create accounts; make an account **player / GM / admin** |

- **Ctrl+Q** closes the screen and asks whether to stop the server or leave it running.
- `./daoc-admin` reopens the screen later.
- `./daoc-server.sh stop` stops the server from any terminal. It saves first.

Rebuilding replaces what the build owns (`bin/`, `defaults/` and the scripts) and keeps `config/`,
`data/`, `logs/` and `run/`. New world data does not reach an existing `data/`; see
[docs/RUN.md](docs/RUN.md).

Point the game client at this machine on port **10300**. Accounts are created on first login. To
make yours an admin, go to the **Accounts** tab, or run `./daoc-admin accounts set-role <account> admin`.

**Players on other machines:**
1. Edit `config/serverconfig.xml` and set `<RegionIP>` to this machine's LAN address (for
   example `192.168.1.20`), or to your public address when port-forwarding.
2. Restart the server.
3. Players connect to that address. Forward TCP 10300 and UDP 10400 on your router to let in
   players from outside your home network.

## Release assets

The `macos-build` workflow builds every push to `main` and to the `macos-*` branches on a macOS
runner and publishes the result to a GitHub release named `macos-<game version>-<12-char commit>`:

```
daoc-server-<game version>-<12-char commit>-osx-arm64.tar.xz         the server folder, one root folder daoc-server/
daoc-server-<game version>-<12-char commit>-osx-arm64.tar.xz.sha256  its checksum (shasum -a 256 format)
```

A published asset is never replaced. `tools/pack.sh` makes the same tarball from a local build.
See [docs/RELEASING.md](docs/RELEASING.md).

## Interface with OfflineDAoC-macOS

[OfflineDAoC-macOS](https://github.com/trozzelle/OfflineDAoC-macOS) installs, starts, stops and
administers this server through the interface below. **Changing any of it needs a matching change
in OfflineDAoC-macOS**, released together; do not change it on its own.

- **Folder layout.** `bin/`, `defaults/` and `navmesh/` plus the top-level scripts and files
  (`daoc-server.sh`, `admin-socket.sh`, `daoc-admin`, `daoc-progress`, `navmesh-install.sh`,
  `release.conf`, `README.md`, `VERSION`) belong to the build and are replaced on an update.
  `config/`, `data/`, `logs/` and `run/` are the user's; an update never touches them and a
  release tarball never contains them.
- **`daoc-server.sh start [--console|--detach] | stop | status`.** `start` opens the admin screen in
  a terminal, runs the console in the foreground with `--console` (or without a terminal), and with
  `--detach` starts in the background, waits until the server is listening and returns (exit 0 when
  ready or already running, 1 when it died or is not ready after 180 s). `status` prints
  `running (pid N)` or `stopped`.
- **`daoc-admin <command> [--json]`.** The same commands as the admin screen, one per call.
  `--json` prints the result as JSON; the commands and their JSON shapes are what OfflineDAoC-macOS
  reads.
- **The admin socket.** `run/admin.sock` inside the server folder, mode 0600, no network port.
  When that path is longer than 100 bytes (a unix socket path holds 104 on macOS), the socket is
  `daoc-<cksum of the folder path>.sock` in the user's private temp folder
  (`getconf DARWIN_USER_TEMP_DIR`). `admin-socket.sh` is the one place this rule lives; the
  server script and `daoc-admin` source it, and `DAOC_ADMIN_SOCKET` overrides it.
- **The tarball.** Named `daoc-server-<game version>-<12-char commit>-osx-arm64.tar.xz`, with the
  single root folder `daoc-server/`, symlinks kept (`bin/config`, `bin/navmesh` and `bin/logs`
  point at the folder's own directories), and `<tarball>.sha256` beside it.
- **`.daoc-pin.json`.** `daoc-server/.daoc-pin.json` in the tarball records where the build came
  from: `{"upstream": "<repository URL>", "ref": "<full commit>", "branch": "<branch or empty>"}`.
  OfflineDAoC-macOS checks `ref` against the commit it asked for.
- **The build.** OfflineDAoC-macOS builds older server commits itself by laying its own build
  pipeline over a clone, so `src/`, `deploy/release.conf`, `deploy/README-release.md`,
  `deploy/serverconfig.template.xml`, `world/patches/`, `world/classic-quests.json`,
  `world/classic-quest-guides.json` and `world/navmesh/` stay where they are.

## ## What's in the game

- **World:** Classic + Shrouded Isles (the Offline DAoC 0.37 world), with Darkness Falls, the
  Realm Exchange and stablemaster routes.
- **Autonomous bots:** persistent characters that level, hunt, travel, group, raid and fight in
  RvR on their own. Manage them in the admin screen's Bots and Population tabs.
- **Companion bots:** summon helpers into your group:

  | Command | What |
  |---|---|
  | `/spawn [class]` | Companion class menu, or a companion of that class |
  | `/classes` | Your realm's classes and their party roles |
  | `/aggressive`, `/defensive` | Companions assist you, or wait for enemies to approach |
  | `/pull`, `/grind` | Order an engage; stationary automatic pulls |
  | `/raid 40`, `/raid 80` | A level-50 companion raid |
  | `/tele <bot>`, `/mobs`, `/stables` | Teleport to a bot or camp; monsters by level; stable routes |

## More

- [deploy/README-release.md](deploy/README-release.md): the guide shipped inside the server folder
  (all admin commands, upgrading)
- [docs/RUN.md](docs/RUN.md): running and administering a server
- [docs/BUILD.md](docs/BUILD.md): building on macOS, testing and project layout
- [docs/BOTS-DEV.md](docs/BOTS-DEV.md): working on the bots (code map, 15-second dev loop)
- [docs/RELEASING.md](docs/RELEASING.md): CI releases, navmesh set, world data
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how the system fits together, decisions, known issues
- [AGENTS.md](AGENTS.md): start here as a contributor or AI assistant (folders, environment, rules)

## License

GPL v3. Based on OpenDAoC; see [src/LICENSE](src/LICENSE).
