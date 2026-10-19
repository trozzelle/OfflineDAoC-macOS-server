# Taking changes from upstream

Layout rule: **each thing we own or want to replace wholesale has its own folder.** Upstream merges
then touch only the folders they map to.

| Folder | What | Upstream? |
|---|---|---|
| `src/Bots/` | All bot code and bot data (`GameBot`, `BotBrain`, `autonomous/`, companions, policies). Compiled **into the GameServer assembly** (`<Compile Include="..\Bots\**\*.cs">` in `GameServer.csproj`), namespaces unchanged. | Offline DAoC `source/server/GameServer/bots/` |
| `src/Admin.Host/` | Server side of the admin TUI: `AdminService`, the Unix socket host, console commands, bot roster and options operations. Own project; depends on GameServer, not the reverse. | none, ours only |
| `src/Admin.Protocol/`, `src/DaocAdmin/` | Wire protocol and the TUI/CLI. | none, ours only |
| `src/WorldBuilder/` | World DB builder. | none, ours only |
| `src/GameServer`, `CoreServer`, `CoreBase`, `CoreDatabase`, `Pathing`, `sharedModules`, `Tests` | Server core. Small local changes on top of upstream (listed in `UPSTREAM.md`). | Offline DAoC `source/server/<same>` |

No client code, launcher or release tooling from upstream is imported. Ever.

## The two seams between us and upstream core

- **Bots to core:** bots are NPCs pretending to be players, so core files special-case them.
  `tools/upstream/bot-touchpoints.sh` lists every non-Bots file that mentions a bot type. After a
  sync, review the ones the sync changed.
- **Admin to core:** exactly two, both explicit. `CoreServer/Actions/ConsoleStart.cs` calls
  `AdminHost.Register()` before the server is created, and `LoginRequestHandler.NewAccountPrivLevelProvider`
  is a hook that `AdminHost.Register()` fills in. Nothing else in GameServer knows the admin module exists.

## Pulling from Offline DAoC

Before a sync moves `main` to a new version, check that the version `main` holds has its own
`macos-<version>` branch (OfflineDAoC-macOS pins and updates follow it). The branches are protected:
never force-push or delete them, since shipped pins name their commits.

```bash
tools/upstream/sync.sh offlinedaoc report v0.37     # files that changed, with our paths
tools/upstream/sync.sh offlinedaoc check  v0.37     # do the patches apply cleanly?
git switch -c sync-0.37
tools/upstream/sync.sh offlinedaoc apply  v0.37     # needs a clean tree; leaves .rej files on conflict
```

`apply` takes `--bots` (only `src/Bots`) or `--core` (only the rest). Bot logic is the part that
changes most upstream and that we edit least, so a bots-only sync is the common, safe case.

Then: build and test (docs/BUILD.md), resolve `.rej` files, run `bot-touchpoints.sh` against the
changed files, update `UPSTREAM.md`, `offlinedaoc_SYNCED` in `tools/upstream/upstreams.conf` and
`AdminService.OfflineDaocVersion` (the version the TUI shows), all in the same commit. Upstream tags can share a commit (v0.36, v0.36b and v0.36c are one), so record the sha.

Conflicts in `src/Bots` mean we edited upstream bot code. Prefer moving our change out into a new
file in `src/Bots/` (a policy class, a partial) so the upstream file can be replaced as-is.

## OpenDAoC (framework only)

Not synced yet and not required for this iteration. Offline DAoC forked OpenDAoC-Core with no
recorded fork point, so there is no `SYNCED` sha and `sync.sh opendaoc` only prints the folder map.
To start: pick an OpenDAoC commit, diff the mapped folders against `src/` by hand, port individual
fixes, and record each in `UPSTREAM.md` as `upstream <sha> -> our commit <sha>: why`. When a
baseline is chosen, set `opendaoc_SYNCED` and `report`/`check`/`apply` will work as for Offline
DAoC (adjust `opendaoc_MAP` if its layout differs).
