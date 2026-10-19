# OfflineDAoC-macOS server

The DAoC server that [OfflineDAoC-macOS](https://github.com/trozzelle/OfflineDAoC-macOS) builds
and runs on macOS: [Offline DAoC](https://github.com/shadowofze/OfflineDAoC)'s OpenDAoC server
with its autonomous and companion bots (synced to 0.37), plus an admin host and TUI, a world
builder, and the Offline DAoC world data and navmeshes. `daoc server install` builds it into one
folder; the macOS build pipeline lives in OfflineDAoC-macOS (`server/tools/build-release.sh`).

## Where it comes from

- Forked on 2026-10-18 from catastrophic-impact's
  [daoc-offline-linux-server-bots](https://github.com/catastrophic-impact/daoc-offline-linux-server-bots)
  (main at `18498ae`, Offline DAoC 0.36), a Linux-first portable build of the same server. Its
  history and branches are kept here; `upstream-0.35` holds the 0.35 line.
- Offline DAoC is tracked directly: `tools/upstream/sync.sh offlinedaoc …` pulls each release's
  server code ([docs/UPSTREAM-SYNC.md](docs/UPSTREAM-SYNC.md), [UPSTREAM.md](UPSTREAM.md)).
- Our own changes are commits on top: macOS fixes and, from here on, our features and macOS
  performance work. Each game version OfflineDAoC-macOS ships has a `macos-<version>` branch
  (`macos-0.35`, `macos-0.36`, `macos-0.37`), which that version's pin and `daoc server update`
  follow. `main` is where the next Offline DAoC sync lands; its version's branch is cut from it
  when OfflineDAoC-macOS ships that version. Fixes for a shipped version go on its branch.

The Linux build instructions below are inherited from the Linux repo and are not tested here (a
server-only folder; the game client is not included).

## Quick start

### What you need

**To run the server:** x86-64 Linux with glibc 2.34 or newer (Ubuntu 22.04+, Debian 12+,
Fedora 35+, SteamOS, Arch) and libicu (almost every distro has it). Nothing else; .NET is bundled.

**To build it, either:**
- **distrobox** (step 2a, recommended). It's preinstalled on SteamOS and packaged by most distros
  (https://distrobox.it). The build tools go into a container, not onto your system. **Or:**
- the **.NET 10 SDK, cmake, g++ and curl** installed yourself (step 2b).

Also: about **6 GB** of free disk space, and internet for the first build (for the build container and tools; the world database and navmeshes are already in the source).

Everything else is in the source, including the world and the navmeshes (`world/navmesh/`, one
compressed file per mesh, about 360 MB in all).

### 1. Get the source

```bash
git clone https://github.com/trozzelle/OfflineDAoC-macOS-server.git
cd OfflineDAoC-macOS-server
```

Or download it as a ZIP from GitHub (**Code → Download ZIP**) and unpack it.

### 2a. Build (with distrobox, recommended)

From the source folder:

```bash
tools/setup-build-box.sh --build
```

This one command:
1. Creates a build container (`daoc-server-box`, Ubuntu 22.04).
2. Installs the .NET 10 SDK, cmake and g++ inside it. Nothing is installed on your system.
3. Builds the server, the world and the navmeshes into `dist/daoc-server`.

The first run takes several minutes. Re-running it is safe.

### 2b. Build (without distrobox)

Install the **.NET 10 SDK**, **cmake**, **g++** and **curl** with your package manager, then run
`tools/build-release.sh`.

### 3. The result

```
dist/daoc-server/                              <- the server, ready to start (world and navmeshes installed)
dist/daoc-server-<version>-linux-x64.tar.gz    <- the server without navmeshes, as one file
dist/daoc-navmeshes-classic-si-4.tar.xz        <- the navmeshes, as one file
```

To run it on another Linux machine, copy `dist/daoc-server` (or the two archives, then run
`./navmesh-install.sh` with the navmesh archive next to the folder). It needs no distrobox and no
.NET there.

### 4. Start the server

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

Rebuilding replaces `dist/daoc-server`, including its world and saves. To keep a world you play
on, run your server from a copy outside `dist/`, and upgrade it as described in
[docs/RUN.md](docs/RUN.md).

### 5. Connect with the game client

Point the DAoC client at this machine on port **10300**. For example, with the Offline DAoC
client under Wine on the same machine:

```bash
wine connect.exe game.dll 127.0.0.1 <account> <password>
```

Accounts are created on first login. To make yours an admin, go to the **Accounts** tab, or run
`./daoc-admin accounts set-role <account> admin`.

**Players on other machines:**
1. Edit `config/serverconfig.xml` and set `<RegionIP>` to this machine's LAN address (for
   example `192.168.1.20`), or to your public address when port-forwarding.
2. Restart the server.
3. Players connect to that address. Forward TCP 10300 and UDP 10400 on your router to let in
   players from outside your home network.

## What's in the game

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
- [docs/BUILD.md](docs/BUILD.md): building, testing and project layout
- [docs/BOTS-DEV.md](docs/BOTS-DEV.md): working on the bots (code map, 15-second dev loop)
- [docs/RELEASING.md](docs/RELEASING.md): publishing releases, navmesh set, world data
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how the system fits together, decisions, known issues
- [AGENTS.md](AGENTS.md): start here as a contributor or AI assistant (folders, environment, rules)

## License

GPL v3. Based on OpenDAoC; see [src/LICENSE](src/LICENSE).
