// Ported from Offline DAoC's progress importer (shadowofze/OfflineDAoC,
// source/tools/OfflineDaoc.ProgressImport/ImportEngine.cs at v0.35 d337d18, GPL-3.0; upstream's v0.36
// changes (0c767c4) add only its release label and the Windows new-client process check, which
// daoc covers on macOS by stopping the client first, and v0.37's (ab4df02) only its release label and
// offline_world_bot_guild in progress-policy.json): the same table policy (progress-policy.json),
// per-table row and content verification, item-template and house handling, Sluaghbinder edition
// guard, and rollback. Adapted to this server folder (data/, defaults/, config/edition, run/): no
// account.txt, account roles are kept, an in-place world upgrade keeps the install's own settings,
// and an upgrade can move a save into the other edition's world. Differences are documented in
// server/README.md.
using System.Data.SQLite;
using System.Diagnostics;
using System.Text.Json;

namespace DaocProgress;

public sealed record Policy(string[] ProgressTables, string[] ClearTables);

public sealed record SaveSummary(string Database, long Accounts, long Characters, long Bots, long InventoryItems,
    long SluaghbinderCharacters, long SluaghbinderBots);

public sealed record ImportResult(string BackupFolder, IReadOnlyList<string> Notes);

public static class ImportEngine
{
    public const string SaveFile = "opendaoc.sqlite3.db";
    const int SluaghbinderClass = 63, AcolyteClass = 16, Hibernia = 3;

    // Server properties that belong to the install rather than the world: the edition, the
    // daoc-admin population and options switches, and the experience rates. An upgrade keeps them.
    static readonly string[] InstallSettings =
    [
        "enable_sluaghbinder", "population_enabled", "max_active_bots",
        "rvr_battleground_announcements", "pve_realm_event_announcements", "bot_use_town_teleporters",
        "bot_route_threat_awareness", "baf_companion_bots_count", "rvr_siege_staged_assault", "rvr_siege_defense_ratio",
        "xp_rate", "bot_xp_rate", "rp_rate", "bp_rate",
    ];

    public static Policy Rules { get; } = JsonSerializer.Deserialize<Policy>(
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "progress-policy.json")))!;

    /// <summary>The save database in a server folder (data/), a Windows Offline DAoC folder
    /// (runtime/data/), a data folder, or the database file itself.</summary>
    public static string LocateSave(string path)
    {
        path = Path.GetFullPath(path);
        if (File.Exists(path)) return path;
        foreach (string candidate in new[] { Path.Combine(path, "data", SaveFile), Path.Combine(path, "runtime", "data", SaveFile), Path.Combine(path, SaveFile) })
            if (File.Exists(candidate)) return candidate;
        throw new InvalidOperationException($"No saved progress found in {path} (looked for data/{SaveFile} and runtime/data/{SaveFile}).");
    }

    /// <summary>What a save contains. A save that isn't this install's own is read from a copy
    /// (see <see cref="CopySave"/>), so its folder is never written to.</summary>
    public static SaveSummary InspectCopy(string database)
    {
        string folder = Directory.CreateTempSubdirectory("daoc-progress-").FullName;
        try { return Inspect(CopySave(database, Path.Combine(folder, SaveFile))) with { Database = database }; }
        finally { Directory.Delete(folder, recursive: true); }
    }

    static SaveSummary Inspect(string database)
    {
        using var c = Open(database, true);
        var tables = Tables(c);
        foreach (string t in new[] { "Account", "DOLCharacters", "offline_world_bots", "Inventory", "ItemUnique", "ItemTemplate" })
            if (!tables.Contains(t))
                throw new InvalidDataException($"The save is missing table {t}; it is not a compatible Offline DAoC save. Nothing was changed.");
        return new SaveSummary(database,
            Scalar(c, "SELECT count(*) FROM Account"), Scalar(c, "SELECT count(*) FROM DOLCharacters"),
            Scalar(c, "SELECT count(*) FROM offline_world_bots"), Scalar(c, "SELECT count(*) FROM Inventory"),
            Scalar(c, $"SELECT count(*) FROM DOLCharacters WHERE Class={SluaghbinderClass} OR (Class={AcolyteClass} AND Realm={Hibernia})"),
            Scalar(c, $"SELECT count(*) FROM offline_world_bots WHERE ClassId={SluaghbinderClass}"));
    }

    /// <summary>
    /// Moves this server's own save into the world this build ships for an edition, keeping this
    /// install's settings, and installs the result as data/. The edition is the given one, else
    /// config/edition, else none: then the save keeps its own enable_sluaghbinder in the Classic
    /// world (defaults/world.sqlite), as before editions were chosen.
    /// </summary>
    public static ImportResult Upgrade(string home, Action<string> progress, bool leaveSluaghbinderBots, string? edition)
    {
        home = ServerFolder(home);
        string data = SavePath(home);
        if (!File.Exists(data))
            throw new InvalidOperationException($"There is no saved progress to upgrade: {data} does not exist. The server creates a fresh world on first start.");
        return Transfer(home, data, upgrade: true, progress, leaveSluaghbinderBots, ResolveEdition(home, edition));
    }

    public const string Sluaghbinder = "sluaghbinder", Classic = "classic";

    /// <summary>The given edition, else config/edition's, else null.</summary>
    static string? ResolveEdition(string home, string? edition)
    {
        string file = Path.Combine(home, "config", "edition");
        edition ??= File.Exists(file) ? File.ReadAllText(file).Trim() : null;
        if (edition is not (null or Sluaghbinder or Classic))
            throw new InvalidOperationException($"Unknown edition '{edition}' (expected {Sluaghbinder} or {Classic}; see {file}).");
        return edition;
    }

    /// <summary>The world a fresh or upgraded save of an edition starts from.</summary>
    static string WorldOf(string home, string? edition) =>
        Path.Combine(home, "defaults", edition == Sluaghbinder ? "world-sluaghbinder.sqlite" : "world.sqlite");

    /// <summary>
    /// Replaces this server's progress with another save's (an older server folder or a Windows
    /// Offline DAoC folder) and installs the result as data/. This server keeps its own world and settings.
    /// </summary>
    public static ImportResult Import(string home, string source, Action<string> progress, bool leaveSluaghbinderBots)
    {
        home = ServerFolder(home);
        string data = SavePath(home);
        if (File.Exists(data) && SameFile(source, data))
            throw new InvalidOperationException("The source is this server's own save. Use 'upgrade' to move it into the new world.");
        if (InstallOf(source) is { } sourceHome) RequireStopped(sourceHome);
        return Transfer(home, source, upgrade: false, progress, leaveSluaghbinderBots, ResolveEdition(home, null));
    }

    static string ServerFolder(string home)
    {
        home = Path.GetFullPath(home);
        if (!File.Exists(Path.Combine(home, "defaults", "world.sqlite")))
            throw new InvalidOperationException($"{home} is not a server folder (no defaults/world.sqlite).");
        return home;
    }

    static string SavePath(string home) => Path.Combine(home, "data", SaveFile);

    static ImportResult Transfer(string home, string source, bool upgrade, Action<string> progress, bool leaveSluaghbinderBots,
        string? edition)
    {
        string data = SavePath(home), world = WorldOf(home, edition);
        if (!File.Exists(world))
            throw new InvalidOperationException($"This build has no {Path.GetFileName(world)}; rebuild the server (daoc server install).");
        // An upgrade into a chosen edition takes the edition from the target, not the old save.
        bool editionChosen = upgrade && edition != null;
        RequireStopped(home);

        Directory.CreateDirectory(Path.Combine(home, "data"));
        using var exclusive = new FileStream(Path.Combine(home, "data", "progress-import.lock"), FileMode.OpenOrCreate,
            FileAccess.ReadWrite, FileShare.None, 1, FileOptions.DeleteOnClose);
        string backup = Path.Combine(home, "data", "progress-backups", DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..6]);
        Directory.CreateDirectory(backup);
        string previous = Path.Combine(backup, SaveFile), staged = Path.Combine(backup, "prepared.db");
        string snapshot = upgrade ? previous : Path.Combine(backup, "source-snapshot.db");
        bool hadSave = File.Exists(data), swapped = false;
        // The result starts as a copy of this database: the shipped world on upgrade or a first
        // import, otherwise this server's own save (its world, settings and progress tables).
        string target = upgrade || !hadSave ? world : data;
        var notes = new List<string>
        {
            upgrade ? $"Upgrade: this server's progress moved into the world from {world}."
                    : $"Import from {source}; this server keeps its own world and settings.",
        };
        try
        {
            progress("Backing up the current save and taking a consistent snapshot of the source…");
            if (hadSave) Backup(data, previous);
            if (!upgrade) CopySave(source, snapshot);
            var summary = Inspect(snapshot);
            notes.Add($"Source: {summary.Accounts} account(s), {summary.Characters} character(s), {summary.Bots} bot(s), {summary.InventoryItems} inventory entries.");
            bool customClass;
            if (editionChosen) customClass = edition == Sluaghbinder;
            else using (var c = Open(upgrade ? previous : target, true)) customClass = SluaghbinderEnabled(c);
            if (editionChosen)
                notes.Add($"Edition: {edition} (enable_sluaghbinder = {(customClass ? "True" : "False")}).");
            if (!customClass && summary.SluaghbinderCharacters > 0)
                throw new InvalidDataException($"The save has {summary.SluaghbinderCharacters} Sluaghbinder character(s), but this server runs without the custom class " +
                    "(server property enable_sluaghbinder = False). Nothing was changed.");
            bool dropBots = !customClass && summary.SluaghbinderBots > 0;
            if (dropBots && !leaveSluaghbinderBots)
                throw new InvalidDataException($"The save has {summary.SluaghbinderBots} autonomous Sluaghbinder bot(s), but this server runs without the custom class. " +
                    "Run again with --leave-sluaghbinder-bots to bring every other bot and leave those (and the items they carry) behind. Nothing was changed.");
            Backup(target, staged);
            long existingMissing;
            using (var c = Open(staged, false))
            {
                Exec(c, "PRAGMA foreign_keys=OFF; PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;");
                using (var attach = c.CreateCommand())
                {
                    attach.CommandText = "ATTACH DATABASE @path AS old";
                    attach.Parameters.AddWithValue("@path", snapshot);
                    attach.ExecuteNonQuery();
                }
                var sourceTables = Tables(c, "old");
                var targetTables = Tables(c);
                var policyTables = new HashSet<string>(Rules.ProgressTables, StringComparer.OrdinalIgnoreCase);
                foreach (string unknown in sourceTables.Except(targetTables, StringComparer.OrdinalIgnoreCase)
                             .Where(t => !t.StartsWith("sqlite_", StringComparison.OrdinalIgnoreCase) && !policyTables.Contains(t)))
                    if (Scalar(c, $"SELECT count(*) FROM old.{Q(unknown)}") is var rows and > 0)
                        notes.Add($"Not transferred: table {unknown} ({rows} rows) is not used by this server.");
                // An owned house whose lot this world doesn't have would vanish along with its contents.
                if (sourceTables.Contains("DBHouse") && targetTables.Contains("DBHouse") && Text(c,
                        "SELECT group_concat(HouseNumber, ', ') FROM old.DBHouse WHERE COALESCE(OwnerID,'')<>'' AND HouseNumber NOT IN (SELECT HouseNumber FROM main.DBHouse)") is { } lost)
                    throw new InvalidDataException($"The world has no lot for owned house(s) {lost}, so they and their contents would be lost. Nothing was changed.");
                Exec(c, "BEGIN IMMEDIATE");
                foreach (string table in Rules.ProgressTables)
                {
                    bool inSource = sourceTables.Contains(table);
                    if (!targetTables.Contains(table))
                    {
                        // Tables the Windows launcher owned (e.g. offline_auction_*) don't exist in this server lineage.
                        if (inSource && Scalar(c, $"SELECT count(*) FROM old.{Q(table)}") is var rows and > 0)
                            notes.Add($"Not transferred: table {table} ({rows} rows) is not used by this server.");
                        continue;
                    }
                    Exec(c, $"DELETE FROM main.{Q(table)}");
                    if (!inSource) continue;
                    var shared = SharedColumns(c, table);
                    var dropped = Columns(c, table, "old").Except(shared, StringComparer.OrdinalIgnoreCase).ToList();
                    if (dropped.Count > 0) notes.Add($"{table}: old-only column(s) {string.Join(", ", dropped)} are not used by this server and were left behind.");
                    string fields = string.Join(",", shared.Select(Q));
                    progress($"Transferring {table}…");
                    Exec(c, $"INSERT INTO main.{Q(table)} ({fields}) SELECT {fields} FROM old.{Q(table)}");
                    if (Scalar(c, $"SELECT count(*) FROM main.{Q(table)}") != Scalar(c, $"SELECT count(*) FROM old.{Q(table)}"))
                        throw new InvalidDataException($"Row verification failed for {table}.");
                    if (Scalar(c, $"SELECT count(*) FROM (SELECT {fields} FROM old.{Q(table)} EXCEPT SELECT {fields} FROM main.{Q(table)})") != 0)
                        throw new InvalidDataException($"Content verification failed for {table}.");
                }
                if (dropBots)
                {
                    // Only autonomous bots of the disabled class; their carried items go with them.
                    progress("Leaving the Sluaghbinder bots behind (this server runs without the custom class)…");
                    string owners = $"SELECT 'offlinebot:'||BotId FROM main.offline_world_bots WHERE ClassId={SluaghbinderClass}";
                    long items = Scalar(c, $"SELECT count(*) FROM main.Inventory WHERE OwnerID IN ({owners})");
                    Exec(c, $"CREATE TEMP TABLE dropped_unique AS SELECT DISTINCT UTemplate_Id AS Id FROM main.Inventory WHERE OwnerID IN ({owners}) AND COALESCE(UTemplate_Id,'')<>''");
                    Exec(c, $"DELETE FROM main.Inventory WHERE OwnerID IN ({owners})");
                    Exec(c, "DELETE FROM main.ItemUnique WHERE Id_nb IN (SELECT Id FROM dropped_unique) AND Id_nb NOT IN (SELECT UTemplate_Id FROM main.Inventory WHERE COALESCE(UTemplate_Id,'')<>'')");
                    // Their guild memberships (0.37 on) go with them.
                    if (targetTables.Contains("offline_world_bot_guild"))
                        Exec(c, $"DELETE FROM main.offline_world_bot_guild WHERE BotId IN (SELECT BotId FROM main.offline_world_bots WHERE ClassId={SluaghbinderClass})");
                    long bots = Scalar(c, $"SELECT count(*) FROM main.offline_world_bots WHERE ClassId={SluaghbinderClass}");
                    Exec(c, $"DELETE FROM main.offline_world_bots WHERE ClassId={SluaghbinderClass}; DROP TABLE dropped_unique;");
                    notes.Add($"Left behind by choice: {bots} autonomous Sluaghbinder bot(s) and the {items} item(s) they carried.");
                }
                // Every old template the world doesn't define: custom items and templates the new world
                // dropped. Owned items reference them from several progress tables (Inventory,
                // househookpointitem, CharacterXOneTimeDrop), so none are filtered out. The
                // world's own definition wins on an ID collision.
                string templateFields = string.Join(",", SharedColumns(c, "ItemTemplate").Select(Q));
                Exec(c, $"INSERT OR IGNORE INTO main.ItemTemplate ({templateFields}) SELECT {templateFields} FROM old.ItemTemplate");
                if (sourceTables.Contains("DBHouse") && targetTables.Contains("DBHouse"))
                {
                    Exec(c, "UPDATE main.DBHouse SET OwnerID='',GuildName='',GuildHouse=0,HasConsignment=0,KeptMoney=0,Model=0,Name='' WHERE COALESCE(OwnerID,'')<>''");
                    var fields = SharedColumns(c, "DBHouse")
                        .Except(new[] { "HouseNumber", "X", "Y", "Z", "RegionID", "Heading", "DBHouse_ID" }, StringComparer.OrdinalIgnoreCase).ToArray();
                    Exec(c, "UPDATE main.DBHouse SET " + string.Join(",", fields.Select(f => $"{Q(f)}=(SELECT o.{Q(f)} FROM old.DBHouse o WHERE o.HouseNumber=main.DBHouse.HouseNumber)")) +
                        " WHERE HouseNumber IN (SELECT HouseNumber FROM old.DBHouse WHERE COALESCE(OwnerID,'')<>'')");
                }
                foreach (string table in Rules.ClearTables)
                    if (targetTables.Contains(table)) Exec(c, $"DELETE FROM main.{Q(table)}");
                if (upgrade) KeepInstallSettings(c, notes, keepEdition: !editionChosen);
                Exec(c, "UPDATE main.offline_world_bots SET IsOnline=0");
                if (!upgrade && Scalar(c, "SELECT count(*) FROM main.offline_world_bots WHERE IsRetired=0") > 0)
                {
                    // As when bots are created: turn the population on so the imported bots log in.
                    Exec(c, "UPDATE main.ServerProperty SET Value='true' WHERE `Key`='population_enabled'");
                    notes.Add("Population turned on so the imported bots log in.");
                }
                string Missing(string schema) => $"SELECT i.Inventory_ID FROM {schema}.Inventory i WHERE (COALESCE(i.UTemplate_Id,'')<>'' AND NOT EXISTS(SELECT 1 FROM {schema}.ItemUnique u WHERE u.Id_nb=i.UTemplate_Id)) OR (COALESCE(i.UTemplate_Id,'')='' AND COALESCE(i.ITemplate_Id,'')<>'' AND NOT EXISTS(SELECT 1 FROM {schema}.ItemTemplate t WHERE t.Id_nb=i.ITemplate_Id))";
                existingMissing = Scalar(c, $"SELECT count(*) FROM ({Missing("old")})");
                if (Scalar(c, $"SELECT count(*) FROM ({Missing("main")} EXCEPT {Missing("old")})") != 0)
                    throw new InvalidDataException("The transfer would leave inventory items without a definition. Nothing was installed.");
                if (existingMissing > 0)
                    notes.Add($"Source-save warning: {existingMissing} inventory entries already lacked an item definition in the source. They were kept unchanged.");
                Exec(c, "COMMIT; DETACH DATABASE old;");
                Integrity(c);
            }

            progress("Installing the verified save…");
            RequireStopped(home);
            if (hadSave)
                using (var c = Open(data, false)) Exec(c, "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;");
            // A leftover -wal from the old database would be replayed into the new one.
            foreach (string suffix in new[] { "-wal", "-shm", "-journal" }) File.Delete(data + suffix);
            File.Move(staged, data, overwrite: true);
            swapped = true;
            using (var verified = Open(data, true)) Integrity(verified);
            if (!upgrade) File.Delete(snapshot);
            notes.Add(hadSave ? $"Rollback copy of the previous save: {previous}" : "There was no previous save.");
            File.WriteAllLines(Path.Combine(backup, "import-report.txt"), notes);
            return new ImportResult(backup, notes);
        }
        catch
        {
            if (swapped)
            {
                if (hadSave)
                {
                    string restore = Path.Combine(backup, "restore.db");
                    File.Copy(previous, restore, overwrite: true);
                    File.Move(restore, data, overwrite: true);
                }
                else File.Delete(data);
            }
            else
            {
                // Nothing was installed: the backup folder holds only copies.
                Directory.Delete(backup, recursive: true);
            }
            throw;
        }
    }

    static void KeepInstallSettings(SQLiteConnection c, List<string> notes, bool keepEdition)
    {
        if (!Tables(c, "old").Contains("ServerProperty") || !Tables(c).Contains("ServerProperty")) return;
        string fields = string.Join(",", SharedColumns(c, "ServerProperty").Select(Q));
        foreach (string key in InstallSettings.Where(k => keepEdition || k != "enable_sluaghbinder"))
        {
            string? kept = Text(c, "SELECT Value FROM old.ServerProperty WHERE `Key`=@key", key);
            if (kept == null) continue;
            string? shipped = Text(c, "SELECT Value FROM main.ServerProperty WHERE `Key`=@key", key);
            if (shipped == kept) continue;
            using var q = c.CreateCommand();
            q.Parameters.AddWithValue("@key", key);
            if (shipped == null)
                q.CommandText = $"INSERT INTO main.ServerProperty ({fields}) SELECT {fields} FROM old.ServerProperty WHERE `Key`=@key";
            else
            {
                q.CommandText = "UPDATE main.ServerProperty SET Value=@value WHERE `Key`=@key";
                q.Parameters.AddWithValue("@value", kept);
            }
            q.ExecuteNonQuery();
            notes.Add($"Kept setting {key} = {kept} (the new world ships {shipped ?? "no value"}).");
        }
    }

    /// <summary>Refuses while the server of that folder is running (run/server.pid names a live process).</summary>
    static void RequireStopped(string serverFolder)
    {
        string pidFile = Path.Combine(serverFolder, "run", "server.pid");
        if (!File.Exists(pidFile) || !int.TryParse(File.ReadAllText(pidFile).Trim(), out int pid)) return;
        try
        {
            using var process = Process.GetProcessById(pid);
            if (!process.HasExited)
                throw new InvalidOperationException($"The server in {serverFolder} is running (pid {pid}). Stop it first: ./daoc-server.sh stop");
        }
        catch (ArgumentException) { } // no such process: a stale pid file
    }

    /// <summary>The server folder a save belongs to (…/data/opendaoc.sqlite3.db), if it is one.</summary>
    static string? InstallOf(string database)
    {
        string? dataDir = Path.GetDirectoryName(database);
        return dataDir != null && Path.GetFileName(dataDir) == "data" && Path.GetDirectoryName(dataDir) is { } root
               && Directory.Exists(Path.Combine(root, "bin")) ? root : null;
    }

    // APFS is case-insensitive by default: ~/Development and ~/development are the same file.
    static bool SameFile(string a, string b) => string.Equals(Canonical(a), Canonical(b), StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Copies a save that isn't this install's own (its server is stopped) together with its -wal,
    /// then folds the WAL into the copy. Only the copy is ever opened, so the source folder is never
    /// written to (an open connection there would create -wal/-shm and checkpoint into the source).
    /// </summary>
    static string CopySave(string database, string destination)
    {
        File.Copy(database, destination);
        if (File.Exists(database + "-wal")) File.Copy(database + "-wal", destination + "-wal");
        using (var c = Connect(destination, false)) Exec(c, "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;");
        foreach (string suffix in new[] { "-wal", "-shm" }) File.Delete(destination + suffix);
        return destination;
    }

    /// <summary>The absolute path with every symlinked component resolved (/tmp → /private/tmp).</summary>
    static string Canonical(string path)
    {
        string full = Path.GetFullPath(path), current = Path.GetPathRoot(full)!;
        foreach (string part in full[current.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, part);
            if (new FileInfo(current).LinkTarget is { } target)
                current = Canonical(Path.GetFullPath(target, Path.GetDirectoryName(current)!));
        }
        return current;
    }

    static string Q(string value) => "\"" + value.Replace("\"", "\"\"") + "\"";

    static SQLiteConnection Open(string path, bool readOnly)
    {
        try { return Connect(path, readOnly); }
        // A read-only connection can't open a WAL-mode save whose -shm file doesn't exist yet (a
        // cleanly stopped server's). This is only ever used on this install's own files (its save,
        // defaults/world.sqlite, its backup copies); a normal connection reads them without changing data.
        catch (SQLiteException e) when (readOnly && e.ResultCode == SQLiteErrorCode.CantOpen) { return Connect(path, false); }
    }

    static SQLiteConnection Connect(string path, bool readOnly)
    {
        var builder = new SQLiteConnectionStringBuilder { DataSource = path, ReadOnly = readOnly, FailIfMissing = true, Pooling = false, DefaultTimeout = 10 };
        var c = new SQLiteConnection(builder.ConnectionString);
        try
        {
            c.Open();
            Scalar(c, "SELECT count(*) FROM sqlite_master"); // SQLite opens lazily; surface open errors here
        }
        catch { c.Dispose(); throw; }
        return c;
    }

    static long Scalar(SQLiteConnection c, string sql)
    {
        using var q = c.CreateCommand();
        q.CommandText = sql;
        return Convert.ToInt64(q.ExecuteScalar());
    }

    static string? Text(SQLiteConnection c, string sql, string? key = null)
    {
        using var q = c.CreateCommand();
        q.CommandText = sql;
        if (key != null) q.Parameters.AddWithValue("@key", key);
        return q.ExecuteScalar() is { } value and not DBNull ? Convert.ToString(value) : null;
    }

    static void Exec(SQLiteConnection c, string sql)
    {
        using var q = c.CreateCommand();
        q.CommandText = sql;
        q.ExecuteNonQuery();
    }

    static HashSet<string> Tables(SQLiteConnection c, string schema = "main")
    {
        using var q = c.CreateCommand();
        q.CommandText = $"SELECT name FROM {schema}.sqlite_master WHERE type='table'";
        using var r = q.ExecuteReader();
        var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        while (r.Read()) result.Add(r.GetString(0));
        return result;
    }

    static List<string> Columns(SQLiteConnection c, string table, string schema = "main")
    {
        using var q = c.CreateCommand();
        q.CommandText = $"PRAGMA {schema}.table_info({Q(table)})";
        using var r = q.ExecuteReader();
        var result = new List<string>();
        while (r.Read()) result.Add(r.GetString(1));
        return result;
    }

    /// <summary>The source's (old.) columns of a table that this database also has, in the source's order.</summary>
    static List<string> SharedColumns(SQLiteConnection c, string table)
    {
        var current = Columns(c, table);
        return Columns(c, table, "old").Where(column => current.Contains(column, StringComparer.OrdinalIgnoreCase)).ToList();
    }

    static bool SluaghbinderEnabled(SQLiteConnection c)
    {
        if (!Tables(c).Contains("ServerProperty")) return true;
        using var q = c.CreateCommand();
        q.CommandText = "SELECT Value FROM ServerProperty WHERE `Key`='enable_sluaghbinder' LIMIT 1";
        return q.ExecuteScalar() is not string text || !text.Trim().Equals("false", StringComparison.OrdinalIgnoreCase);
    }

    static void Backup(string source, string destination)
    {
        using var from = Open(source, true);
        using var to = new SQLiteConnection(new SQLiteConnectionStringBuilder { DataSource = destination, Pooling = false }.ConnectionString);
        to.Open();
        from.BackupDatabase(to, "main", "main", -1, null, 0);
    }

    static void Integrity(SQLiteConnection c)
    {
        using var q = c.CreateCommand();
        q.CommandText = "PRAGMA quick_check";
        if (!string.Equals(Convert.ToString(q.ExecuteScalar()), "ok", StringComparison.Ordinal))
            throw new InvalidDataException("Database integrity check failed.");
    }
}
