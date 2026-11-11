# Vendored System.Data.SQLite (1.0.119)

The Linux repo builds against the NuGet package `System.Data.SQLite.Core` 1.0.119, whose native
`SQLite.Interop` binary ships prebuilt for win-x86/x64, linux-x64 and **osx-x64** — there is no
osx-arm64 build, and its interop exports hashed symbol names (`SI0…`) that cannot be reproduced
from the public source.

This directory vendors the managed project source for that exact version (1.0.119.0, source id
`412ff082182b121d74a9ced16159bd0eb496deef`) from the System.Data.SQLite fossil
(`release-1.0.119.0`), trimmed to the NetStandard 2.1 project and its `Targets/` imports, with
two macOS-arm64 patches applied in place:

1. `SQLite3.StaticSetMemoryStatus` — calling the variadic `sqlite3_config` with fixed-argument
   P/Invoke declarations is undefined behaviour on Apple Silicon (variadic arguments are read
   from the stack save area, which a fixed-arg caller never writes; see dotnet/runtime#48752).
   The method is a no-op returning `Ok`; SQLite keeps its default memory-status setting.
2. `SQLite3.SetLogCallback` — same variadic hazard (`sqlite3_config(SQLITE_CONFIG_LOG, …)`);
   registering the callback would read a function pointer from garbage. SQLite logging stays
   disabled; the server's own NLog stack does all logging.

The project is built with `SQLITE_STANDARD` (`UseInteropDll=false`, `UseSqliteStandard=true`) so
it binds the macOS system `libsqlite3` through plain, fixed-argument entry points only — no
`SQLite.Interop` and no variadic calls.

`tools/build-release.sh` compiles this project and overlays the resulting assembly onto the
server, DaocAdmin and WorldBuilder outputs (and deletes the stub package's `runtimes/` tree) so
no output ever probes `SQLite.Interop.dll`.

Reference: Linux repo `UPSTREAM.md` pins OpenDAoC-Database; this vendoring concerns only the
ADO.NET provider, not game data.