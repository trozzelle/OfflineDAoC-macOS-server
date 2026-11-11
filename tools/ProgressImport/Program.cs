using System.Data.SQLite;
using DaocProgress;

const string Usage = """
    Usage (from the server folder, with the server stopped):
      ./daoc-progress upgrade [--edition=sluaghbinder | --edition=classic]
          Move this server's saved progress into the world this build ships for an edition
          (defaults/world-sluaghbinder.sqlite or defaults/world.sqlite; default: config/edition):
          accounts (with their roles), characters, items, money, houses, guilds and bots. This
          install's settings (population, options, XP rates) are kept; the edition is the one
          given, else config/edition's, else the save's own.
      ./daoc-progress import <folder or .db> --replace-progress
          Replace this server's progress with the progress of another save: an older server folder,
          or a Windows Offline DAoC folder (the one containing runtime/). This server keeps its own
          world and settings. The source is only read.
      ./daoc-progress inspect <folder or .db> [--json]
          Show what a save contains. Changes nothing.

    Options:
      --leave-sluaghbinder-bots   when this server runs without the custom class: bring every other
                                  bot and leave Sluaghbinder bots (and the items they carry) behind.

    Every run backs up the current save to data/progress-backups/<time>/ first (with
    import-report.txt). To undo: stop the server, delete data/opendaoc.sqlite3.db-wal and
    data/opendaoc.sqlite3.db-shm if they exist, then copy that folder's opendaoc.sqlite3.db back to data/.
    """;

string home = Environment.GetEnvironmentVariable("DAOC_HOME") is { Length: > 0 } configured
    ? Path.GetFullPath(configured)
    : Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, ".."));
string[] knownFlags = ["--leave-sluaghbinder-bots", "--replace-progress", "--json",
    "--edition=" + ImportEngine.Sluaghbinder, "--edition=" + ImportEngine.Classic];
var flags = args.Where(a => a.StartsWith("--", StringComparison.Ordinal)).ToHashSet();
var words = args.Where(a => !a.StartsWith("--", StringComparison.Ordinal)).ToList();
var editions = flags.Where(f => f.StartsWith("--edition=", StringComparison.Ordinal)).ToList();
if (flags.Except(knownFlags).Any() || words.Count == 0 || editions.Count > 1)
    return Fail(2, Usage);
bool leaveBots = flags.Contains("--leave-sluaghbinder-bots");
string? edition = editions.Count == 1 ? editions[0]["--edition=".Length..] : null;

try
{
    switch (words[0], words.Count)
    {
        case ("inspect", 2):
        {
            var s = ImportEngine.InspectCopy(ImportEngine.LocateSave(words[1]));
            if (flags.Contains("--json"))
            {
                Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new Dictionary<string, long>
                {
                    ["accounts"] = s.Accounts, ["characters"] = s.Characters, ["bots"] = s.Bots,
                    ["inventory"] = s.InventoryItems, ["sluaghbinder_characters"] = s.SluaghbinderCharacters,
                    ["sluaghbinder_bots"] = s.SluaghbinderBots,
                }));
                return 0;
            }
            Console.WriteLine($"{s.Database}\n  {s.Accounts} account(s), {s.Characters} character(s), {s.Bots} bot(s), {s.InventoryItems} inventory entries" +
                (s.SluaghbinderCharacters + s.SluaghbinderBots > 0 ? $"\n  Sluaghbinder: {s.SluaghbinderCharacters} character(s), {s.SluaghbinderBots} bot(s)" : ""));
            return 0;
        }
        case ("upgrade", 1):
            return Report(ImportEngine.Upgrade(home, Console.WriteLine, leaveBots, edition));
        case ("import", 2):
            if (!flags.Contains("--replace-progress"))
                return Fail(2, "import replaces this server's saved progress. Add --replace-progress to confirm (a backup is made first).");
            return Report(ImportEngine.Import(home, ImportEngine.LocateSave(words[1]), Console.WriteLine, leaveBots));
        default:
            return Fail(2, Usage);
    }
}
catch (Exception e) when (e is InvalidOperationException or InvalidDataException or IOException or UnauthorizedAccessException or SQLiteException)
{
    return Fail(1, "daoc-progress: " + e.Message);
}

static int Report(ImportResult result)
{
    foreach (string note in result.Notes) Console.WriteLine("  " + note);
    Console.WriteLine($"Done. Report: {Path.Combine(result.BackupFolder, "import-report.txt")}");
    return 0;
}

static int Fail(int code, string message)
{
    Console.Error.WriteLine(message);
    return code;
}
