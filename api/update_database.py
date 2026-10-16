"""Bring the shop's database up to date with the section files in sql/.

The rules arrive as numbered section files (sql/grooming_platform_schema.sql,
then sql/15_*.sql, sql/16_*.sql, …). A database built on an earlier day is
missing the sections merged since, and a screen that needs one answers 500.
This adds them, on every start of the api service (api/load_demo.sh runs it):

  1. It keeps a list, in the database itself (upkeep.applied_section), of the
     section files already in it.
  2. Anything in sql/ not on the list is new. Before adding anything it takes
     a backup with extraction/review/shop_backup.py (SOP SYS-08).
  3. It adds each new section in order, each in one transaction together with
     its line on the list: a section goes in whole and is listed, or not at
     all. It never runs a listed section again and never rebuilds anything.
  4. If a section fails, it stops there. The database is as it was before
     that section, the failure is kept in upkeep.update_status, and Admin
     shows it with the backup's name. The app still starts.

A database that predates the list is taken to hold every section up to
34_staff.sql, the last one before this existed, except 34 itself when its
view (groom.v_staff) is missing: that is the day this was written for.

  python api/update_database.py                  bring grooming_demo up to date
  python api/update_database.py --built DB       DB was just built from every file: list them all
  python api/update_database.py --sql-dir D DB   use another folder of section files (the tests)
  python api/update_database.py --skip-backup DB don't back up first (the tests only)

The connection comes from PGHOST / PGUSER / PGPASSWORD, as for psql. Seeds
(sql/seed/) are not sections and are never applied here.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BACKUP = REPO / "extraction" / "review" / "shop_backup.py"

# What a database from before this list already holds (see the docstring).
BASELINE_LAST = "34_staff.sql"
BASELINE_CHECKS = {"34_staff.sql": "groom.v_staff"}

SETUP = """
CREATE SCHEMA IF NOT EXISTS upkeep;
CREATE TABLE IF NOT EXISTS upkeep.applied_section (
    file        text PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now(),
    how         text NOT NULL CHECK (how IN ('built', 'baseline', 'update'))
);
CREATE TABLE IF NOT EXISTS upkeep.update_status (
    id           integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    checked_at   timestamptz NOT NULL DEFAULT now(),
    ok           boolean NOT NULL,
    applied      text[] NOT NULL DEFAULT '{}',
    failed_file  text,
    message      text,
    backup       text
);
"""


def say(msg: str = "") -> None:
    print(f"[database update] {msg}" if msg else "", flush=True)


def section_files(sql_dir: Path) -> list[str]:
    """Every section, in the order they load: the schema, then 15_, 16_, …"""
    numbered = sorted(p.name for p in sql_dir.glob("[0-9][0-9]_*.sql"))
    return ["grooming_platform_schema.sql"] + numbered


def lit(text: str | None) -> str:
    return "NULL" if text is None else "'" + text.replace("'", "''") + "'"


def psql(db: str, *args: str) -> subprocess.CompletedProcess:
    env = dict(os.environ, PGOPTIONS="-c client_min_messages=warning")
    return subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", db, *args],
                          capture_output=True, text=True, env=env)


def value(db: str, sql: str) -> str:
    out = psql(db, "-t", "-A", "-c", sql)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip())
    return out.stdout.strip()


def set_status(db: str, ok: bool, applied: list[str], failed: str | None = None,
               message: str | None = None, backup: str | None = None) -> None:
    arr = "ARRAY[" + ",".join(lit(a) for a in applied) + "]::text[]"
    psql(db, "-c", f"""
        INSERT INTO upkeep.update_status (id, checked_at, ok, applied, failed_file, message, backup)
        VALUES (1, now(), {str(ok).lower()}, {arr}, {lit(failed)}, {lit(message)}, {lit(backup)})
        ON CONFLICT (id) DO UPDATE SET checked_at = now(), ok = EXCLUDED.ok, applied = EXCLUDED.applied,
            failed_file = EXCLUDED.failed_file, message = EXCLUDED.message, backup = EXCLUDED.backup""")


def record(db: str, files: list[str], how: str) -> None:
    if files:
        rows = ",".join(f"({lit(f)}, {lit(how)})" for f in files)
        out = psql(db, "-c", f"INSERT INTO upkeep.applied_section (file, how) VALUES {rows} ON CONFLICT DO NOTHING")
        if out.returncode != 0:
            raise RuntimeError(out.stderr.strip())


def baseline(db: str, files: list[str]) -> list[str]:
    """What a database from before the list holds (see the docstring)."""
    held = []
    for f in files:
        if f > BASELINE_LAST and f != "grooming_platform_schema.sql":
            continue
        check = BASELINE_CHECKS.get(f)
        if check and value(db, f"SELECT to_regclass({lit(check)}) IS NOT NULL") != "t":
            continue
        held.append(f)
    return held


def take_backup() -> tuple[str | None, str]:
    """(the backup's file name, or None if it failed; what it said)."""
    out = subprocess.run([sys.executable, str(BACKUP), "save", "--label", "before-update"],
                         capture_output=True, text=True, cwd=REPO)
    said = (out.stdout + out.stderr).strip()
    m = re.search(r"Backup saved: (\S+)", said)
    return (m.group(1) if m and out.returncode == 0 else None), said


def last_lines(text: str, n: int = 6) -> str:
    lines = [l for l in text.strip().splitlines() if l.strip()]
    return "\n".join(lines[-n:])


def update(db: str, sql_dir: Path, skip_backup: bool = False) -> bool:
    """True when the database holds every section. Never raises for a failed section."""
    out = psql(db, "-c", SETUP)
    if out.returncode != 0:
        say(f"Could not reach {db} to check it: {last_lines(out.stderr)}")
        return False

    files = section_files(sql_dir)
    listed = set(value(db, "SELECT file FROM upkeep.applied_section").splitlines())
    if not listed:
        if value(db, "SELECT to_regnamespace('groom') IS NOT NULL") != "t":
            say(f"{db} has no shop schema at all; build it with api/load_demo.sh, not an update.")
            return False
        held = baseline(db, files)
        record(db, held, "baseline")
        listed = set(held)
        say(f"{db} predates the list of sections; it holds {len(held)} of them, up to {held[-1]}.")

    pending = [f for f in files if f not in listed]
    if not pending:
        set_status(db, True, [])
        say(f"{db} is up to date ({len(files)} sections).")
        return True

    say(f"{db} is missing {len(pending)} section(s): {', '.join(pending)}.")
    backup = None
    if not skip_backup:
        say("Backing up first…")
        backup, said = take_backup()
        if backup is None:
            msg = "The backup before the update did not work, so nothing was added.\n" + last_lines(said)
            set_status(db, False, [], pending[0], msg)
            say(msg)
            return False
        say(f"Backup saved: {backup}")

    applied: list[str] = []
    for f in pending:
        # The section and its line on the list, in one transaction.
        out = psql(db, "-1", "-f", str(sql_dir / f),
                   "-c", f"INSERT INTO upkeep.applied_section (file, how) VALUES ({lit(f)}, 'update')")
        if out.returncode != 0:
            msg = last_lines(out.stderr)
            set_status(db, False, applied, f, msg, backup)
            say(f"{f} could not be added, so the update stopped there. "
                f"The database is as it was before {f}.")
            say(msg)
            if backup:
                say(f"The backup taken before the update is {backup}.")
            return False
        applied.append(f)
        say(f"Added {f}.")

    set_status(db, True, applied, backup=backup)
    say(f"{db} is up to date: added {', '.join(applied)}.")
    return True


def main() -> None:
    ap = argparse.ArgumentParser(description="Bring the shop's database up to date with sql/.")
    ap.add_argument("db", nargs="?", default="grooming_demo")
    ap.add_argument("--built", action="store_true", help="The database was just built from every file.")
    ap.add_argument("--sql-dir", type=Path, default=REPO / "sql")
    ap.add_argument("--skip-backup", action="store_true", help="Tests only.")
    a = ap.parse_args()
    if a.built:
        psql(a.db, "-c", SETUP)
        record(a.db, section_files(a.sql_dir), "built")
        set_status(a.db, True, [])
        return
    update(a.db, a.sql_dir, a.skip_backup)
    # Always 0: a failed section is shown in Admin; the app still starts.


if __name__ == "__main__":
    main()
