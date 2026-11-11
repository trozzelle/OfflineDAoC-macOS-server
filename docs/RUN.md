# Running the server

A server is one portable folder (from `tools/build-release.sh`, or a release tarball). Its scripts
work on the folder they are in, so you can run them from anywhere. The folder's own README (`deploy/README-release.md`) is the short player-facing
version of this page.

## First time

```bash
tar -xJf daoc-server-<version>-osx-arm64.tar.xz      # anywhere; creates daoc-server/
cd daoc-server
./daoc-server.sh start
```

On first start the folder creates:
- `data/opendaoc.sqlite3.db`, a fresh Classic + SI world copied from `defaults/world.sqlite`;
- `config/`, from `defaults/`.

The navmeshes are part of the tarball. `navmesh-install.sh --from-dir <folder>` installs another
server's `zone*.nav` files instead. (OfflineDAoC-macOS installs and updates all of this with
`daoc server install` / `daoc server update`.)

## Folder layout

| Path | What | Kept on upgrade |
|---|---|---|
| `bin/` | Server program, `daoc-admin`, bundled .NET, `lib/Detour.dylib` | replaced |
| `defaults/` | `world.sqlite` and config templates | replaced |
| `config/` | `serverconfig.xml`, `logconfig.xml`, `invalidnames.txt`, `admins.json` | **yours** |
| `data/` | `opendaoc.sqlite3.db`: the world, accounts, characters, bots, economy | **yours** |
| `navmesh/` | `zone*.nav` plus `MANIFEST.sha256` | **yours** |
| `logs/` | `server.log`, `error.log`, `warn.log`, `console.out` (this run), `console.prev.out` | |
| `run/` | `server.pid`, `admin.sock` | |
| `daoc-server.sh`, `admin-socket.sh`, `daoc-admin`, `daoc-progress`, `navmesh-install.sh`, `release.conf`, `README.md`, `VERSION` | Scripts and info | replaced |

## Start and stop

```bash
./daoc-server.sh start             # server in the background + admin screen in this terminal
./daoc-server.sh start --console   # raw server console in the foreground (also used when there's no terminal)
./daoc-server.sh start --detach    # background; returns once the server is listening, no admin screen
./daoc-server.sh stop              # saves first
./daoc-server.sh status
./daoc-admin                       # reopen the admin screen
```

- In the admin screen, **Ctrl+Q** asks whether to stop the server or leave it running.
- Closing the terminal doesn't stop a background server.
- Stopping always saves, whether by the Stop button, `daoc-admin server stop`, `exit` in the
  console, Ctrl+C or SIGTERM.
- Only one server can use the game port (10300) at a time; `start` refuses if it's taken.

## Admin

The **admin screen** has six tabs:
- **Server:** status, live log, Stop.
- **Bots:** list, create, delete.
- **Population:** on/off, max in world.
- **Accounts:** create, set player/GM/admin.
- **Options:** announcement, town-teleporter, route-threat, Bring A Friend and siege switches, and
  the bot goal percentages per level bracket (the Windows launcher's Options and Bot Goals).
  Changes apply to the running server at once and are saved (server properties, `bot-goals.json`).
- **RvR:** battlegrounds (bracket, keep owner, bots inside and on the way), keeps, relics, raids.

The **CLI** (`./daoc-admin help`) has the same commands, and they also work typed into the
server console:

```
status | server stop
bots list [--realm alb|mid|hib] [--online]
bots create [--realm alb|mid|hib|all] [--count N] [--level 1|50] [--class NAME]
bots delete <name|id> | bots delete-all --yes
population | population on | off | max <N>
accounts list | show <name> | create <name> <password> | set-role <name> player|gm|admin
options | options set <key> on|off|<number>
goals | goals set <1-19|20-49|50> <solo> <group> <rvr> <battlegrounds>
rvr
```

How it works:
- The server listens on `run/admin.sock` (mode 0600; a short path in your private temp folder if
  the folder path is very long), so there's no network port. Only the OS
  user running the server can administer it; for remote admin, ssh in.
- `config/admins.json` lists GM and admin account names. It's rewritten by the admin tools and
  applied at start and on first login. You can edit it while the server is stopped.
- Code: `src/Admin.Host/` (server side), `src/DaocAdmin` (client), `src/Admin.Protocol`
  (shared).

## Connecting a client

The client is a separate install (OfflineDAoC-macOS runs it under Wine). Point it at this machine
on port 10300. Accounts are created on first login, or with `./daoc-admin accounts create`.

For other machines on your network, set `<RegionIP>` in `config/serverconfig.xml` to this
machine's LAN address and restart. For players outside your network, use your public address and
forward **TCP 10300** and **UDP 10400** on your router.

## Upgrading

1. Stop the server.
2. Back up `data/`.
3. Unpack the new release somewhere.
4. Copy its `bin/`, `defaults/` and scripts over the old folder.
5. Start.

`config/`, `data/`, `logs/`, `run/` and `navmesh/` stay.

**World changes don't reach an existing `data/`.** The world is copied into `data/` only on first
start, so a release with new world data (the 0.35 sync: quests, spawns, server properties) needs a
fresh `data/` to get it. There is no tool yet that carries characters and bots over into a new
world (upstream's Windows `IMPORT PROGRESS` does this). Copy the new release's `navmesh/` too
when the navmesh set changes.

For code-only updates during development, `tools/dev-deploy.sh` does a quick version of this (see
[BOTS-DEV.md](BOTS-DEV.md)).

## Backups

Copy `data/opendaoc.sqlite3.db` while the server is stopped. While it's running, use
`sqlite3 data/opendaoc.sqlite3.db ".backup backup.db"`, which is safe with WAL. Keep backups out
of git.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `port 10300 is already in use` | Another server is running. Stop it, or change `<Port>` in `config/serverconfig.xml`. |
| `no navmeshes yet` | Rebuild the folder (`daoc server install`), or `./navmesh-install.sh --from-dir <folder>`. |
| The client can't connect from another machine | Set `<RegionIP>` to this machine's LAN or public address; check the firewall and router (TCP 10300, UDP 10400). |
| `The server did not start` | Read the lines printed after it, `logs/console.out` and `logs/error.log`. |
| Bots don't appear | Check that the population is on (`./daoc-admin population`) and that bots exist (`bots list`). New bots log in within seconds. |
