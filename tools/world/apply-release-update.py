#!/usr/bin/env python3
"""Apply an Offline DAoC release's world update (db-<edition>.json) to a world database.

From 0.37 on, upstream ships a release as an update to the 0.36 base: the game patch carries
db-0.37.json (plain edition) and db-0.37b.json (Sluaghbinder), which its patcher applies to the
player's runtime/data/opendaoc.sqlite3.db. Upstream never ships the updated database itself, so
this recreates the release's pristine world from the previous one, the same way:

  apply-release-update.py <opendaoc.sqlite3.db> <db-<edition>.json>

A port of WorldUpdate.Apply in upstream's source/tools/OfflineDaoc.Patcher/Program.cs (v0.37,
ab4df02, GPL-3.0), with the same semantics: new tables and columns first, then per table the
released rows added (INSERT OR IGNORE), changed and removed, where a change or removal only
matches a row that still has its released values (IgnoreColumns and the table's IgnoreCompare
are left out of the match). The version is recorded in offline_patch_log, and an update already
recorded there is skipped, as upstream does. The database is changed in place, in one transaction.

Meant for a pristine world: every table's added/changed/removed must equal the JSON's Summary,
with no row "left as the game had them" (where upstream's patcher keeps a player's changed row,
here it means the base was not the release's). Anything else rolls back and exits 1.
"""
import base64
import json
import re
import sqlite3
import sys


def q(name):
    return '"' + name.replace('"', '""') + '"'


def value(v):
    """A JSON value from upstream's make_patch as the SQLite value the patcher binds."""
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, dict):
        return base64.b64decode(v["$b64"])
    if v is None or isinstance(v, (int, float, str)):
        return v
    raise ValueError(f"unexpected value in the world update: {v!r}")


def columns(con, table):
    return [r[1] for r in con.execute(f"PRAGMA table_info({q(table)})")]


def apply(database, update_file):
    with open(update_file, encoding="utf-8") as f:
        root = json.load(f)
    version = root["Version"]
    con = sqlite3.connect(database, isolation_level=None)
    try:
        con.execute("BEGIN")
        con.execute("CREATE TABLE IF NOT EXISTS offline_patch_log (Version TEXT PRIMARY KEY, AppliedUtc TEXT, Notes TEXT)")
        if con.execute("SELECT count(*) FROM offline_patch_log WHERE Version=?", (version,)).fetchone()[0]:
            con.execute("ROLLBACK")
            print(f"World data: already updated to {version}.")
            return
        for t in root["NewTables"]:
            con.execute(_if_not_exists(t["Create"]))
        for col in root["NewColumns"]:
            if col["Column"].lower() not in {c.lower() for c in columns(con, col["Table"])}:
                con.execute(f"ALTER TABLE {q(col['Table'])} ADD COLUMN {q(col['Column'])} {col['Decl']}")
        ignored = {c.lower() for c in root["IgnoreColumns"]}
        added = changed = removed = kept = 0
        notes = []
        counts = {}
        for t in root["Tables"]:
            table, cols = t["Table"], t["Columns"]
            table_ignore = {c.lower() for c in t.get("IgnoreCompare", [])}
            cmp = [i for i, c in enumerate(cols) if c.lower() not in ignored and c.lower() not in table_ignore]
            where = " AND ".join(f"{q(cols[i])} IS ?" for i in cmp)
            table_kept = table_added = table_changed = table_removed = 0
            insert = f"INSERT OR IGNORE INTO {q(table)} ({','.join(map(q, cols))}) VALUES ({','.join('?' * len(cols))})"
            for row in t["Insert"]:
                if con.execute(insert, [value(v) for v in row]).rowcount == 1:
                    table_added += 1
                else:
                    table_kept += 1
            update = f"UPDATE {q(table)} SET {','.join(q(c) + '=?' for c in cols)} WHERE {where}"
            for row in t["Update"]:
                params = [value(v) for v in row["New"]] + [value(row["Old"][i]) for i in cmp]
                if con.execute(update, params).rowcount > 0:
                    table_changed += 1
                else:
                    table_kept += 1
            delete = f"DELETE FROM {q(table)} WHERE {where}"
            for row in t["Delete"]:
                if con.execute(delete, [value(row[i]) for i in cmp]).rowcount > 0:
                    table_removed += 1
                else:
                    table_kept += 1
            if table_kept:
                notes.append(f"{table}: {table_kept} row(s) left as the game had them")
            counts[table] = {"added": table_added, "changed": table_changed, "removed": table_removed}
            added, changed, removed = added + table_added, changed + table_changed, removed + table_removed
            kept += table_kept
        expected = {t: {k: s.get(k, 0) for k in ("added", "changed", "removed")}
                    for t, s in root.get("Summary", {}).items()}
        if kept or counts != expected:
            for table in sorted(set(counts) | set(expected)):
                if counts.get(table) != expected.get(table):
                    print(f"  {table}: applied {counts.get(table)}, Summary {expected.get(table)}", file=sys.stderr)
            for note in notes:
                print("  " + note, file=sys.stderr)
            raise SystemExit(f"{database} is not the world {update_file} was made from; nothing was changed")
        con.execute("INSERT INTO offline_patch_log (Version, AppliedUtc, Notes) VALUES (?, strftime('%Y-%m-%dT%H:%M:%fZ','now'), ?)",
                    (version, "; ".join(notes)))
        con.execute("COMMIT")
    except BaseException:
        if con.in_transaction:
            con.execute("ROLLBACK")
        raise
    finally:
        con.close()
    print(f"World data updated to {version}: {added} added, {changed} changed, {removed} removed, "
          f"{kept} left as the game had them.")
    for note in notes:
        print("  " + note)


def _if_not_exists(sql):
    """CREATE TABLE -> CREATE TABLE IF NOT EXISTS, as the patcher does (every one, case-insensitive)."""
    return re.sub("CREATE TABLE ", lambda _: "CREATE TABLE IF NOT EXISTS ", sql, flags=re.IGNORECASE)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    apply(sys.argv[1], sys.argv[2])
