"""Back up and restore the shop's data: one dated zip file in backups/.

A backup holds everything the shop's records need to come back whole:

  grooming_demo.dump   the shop app's database (clients, dogs, bookings,
                       haircuts, paperwork records), from pg_dump
  grooming_test.dump   the test database, if it exists (cheap, so included)
  private/...          every file in private/: the copies of paperwork and
                       the dog photos the records point to
  manifest.json        when it was made and what is in it

Run it inside the Technical workbench's container, which has the Postgres client
and sees the repo at /repo (see docker-compose.yml). From the
dog-groomer-platform folder:

  docker compose exec review python shop_backup.py save
  docker compose exec review python shop_backup.py list
  docker compose exec review python shop_backup.py restore            (the newest)
  docker compose exec review python shop_backup.py restore <file.zip>

Restore asks before it replaces anything, and first saves a backup of what
is there now, so a restore can itself be undone. It replaces both databases
wholesale and puts back every file in the backup's private/; files added to
private/ since are left where they are. The Run & test screen's Database tab
runs the same commands (restore with --yes, after its own question).

backups/ is gitignored: the zips hold real clients' details and paperwork.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

REPO = Path(__file__).resolve().parents[2]
PRIVATE = REPO / "private"
BACKUPS = REPO / "backups"
DATABASES = ["grooming_demo", "grooming_test"]
REQUIRED = "grooming_demo"   # the shop's records; a backup without it is no backup

# Warnings and errors only: "does not exist, skipping" is not news.
os.environ["PGOPTIONS"] = "-c client_min_messages=warning"


def say(msg: str = "") -> None:
    print(msg, flush=True)


def run(argv: list[str]) -> None:
    """Run a Postgres client command; its own messages go to the screen. Stops on failure."""
    proc = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in proc.stdout.splitlines():
        say("  " + line)
    if proc.returncode != 0:
        raise SystemExit(f"Stopped: {argv[0]} failed (exit {proc.returncode}). Nothing after this step was done.")


def psql_value(sql: str, db: str = "postgres") -> str:
    out = subprocess.run(["psql", "-X", "-q", "-t", "-A", "-d", db, "-c", sql],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit("Stopped: cannot reach the database. Is the app running (docker compose up -d)?\n"
                         + out.stderr.strip())
    return out.stdout.strip()


def existing_databases() -> list[str]:
    names = set(psql_value("SELECT datname FROM pg_database").splitlines())
    return [d for d in DATABASES if d in names]


def private_files() -> list[Path]:
    if not PRIVATE.exists():
        return []
    return sorted(p for p in PRIVATE.rglob("*") if p.is_file())


def size(n: float) -> str:
    for unit in ("bytes", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "bytes" else f"{n:.1f} {unit}"
        n /= 1024
    return ""


# -------------------------------------------------------------------- save

def save(label: str = "") -> Path:
    dbs = existing_databases()
    if REQUIRED not in dbs:
        raise SystemExit(f"Stopped: the {REQUIRED} database does not exist, so there is nothing to back up.")
    BACKUPS.mkdir(exist_ok=True)
    made = datetime.now(timezone.utc)
    name = f"shop-backup-{made:%Y-%m-%d_%H-%M-%S}{'-' + label if label else ''}.zip"
    final = BACKUPS / name
    partial = BACKUPS / (name + ".partial")   # renamed only once complete and checked

    files = private_files()
    with tempfile.TemporaryDirectory() as tmp:
        for db in dbs:
            say(f"Copying the {db} database…")
            dump = Path(tmp) / f"{db}.dump"
            run(["pg_dump", "-d", db, "--format=custom", "--no-owner", "-f", str(dump)])
            check = subprocess.run(["pg_restore", "--list", str(dump)], capture_output=True)
            if check.returncode != 0:
                raise SystemExit(f"Stopped: the copy of {db} could not be read back.")

        say(f"Copying {len(files)} files from private/…")
        manifest = {
            "made_utc": made.isoformat(timespec="seconds"),
            "databases": dbs,
            "private_files": len(files),
            "private_bytes": sum(f.stat().st_size for f in files),
        }
        with zipfile.ZipFile(partial, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("manifest.json", json.dumps(manifest, indent=2))
            for db in dbs:
                z.write(Path(tmp) / f"{db}.dump", f"{db}.dump")
            for f in files:
                z.write(f, f.relative_to(REPO).as_posix())

    with zipfile.ZipFile(partial) as z:
        bad = z.testzip()
    if bad:
        partial.unlink()
        raise SystemExit(f"Stopped: {bad} did not read back correctly. No backup was kept.")
    partial.replace(final)
    say()
    say(f"Backup saved: backups/{name} ({size(final.stat().st_size)})")
    say(f"  databases: {', '.join(dbs)}; files from private/: {len(files)}")
    return final


# -------------------------------------------------------------------- list

def backups() -> list[Path]:
    """Newest first. The name starts with the date and time, so name order is time order."""
    if not BACKUPS.exists():
        return []
    return sorted(BACKUPS.glob("shop-backup-*.zip"), key=lambda p: p.name, reverse=True)


def describe(path: Path) -> str:
    try:
        with zipfile.ZipFile(path) as z:
            m = json.loads(z.read("manifest.json"))
    except (zipfile.BadZipFile, KeyError, ValueError):
        return f"{path.name}  (not a readable backup)"
    return (f"{path.name}  {size(path.stat().st_size)}, databases: {', '.join(m['databases'])}, "
            f"files: {m['private_files']}")


def list_backups() -> None:
    found = backups()
    if not found:
        say("No backups yet. Make one with: docker compose exec review python shop_backup.py save")
        return
    say(f"Backups in backups/ (newest first; times are UTC):")
    for p in found:
        say("  " + describe(p))


# ----------------------------------------------------------------- restore

def resolve(name: str | None) -> Path:
    if not name:
        found = backups()
        if not found:
            raise SystemExit("Stopped: there are no backups in backups/ to restore.")
        return found[0]
    p = Path(name)
    for candidate in (p, BACKUPS / p.name):
        if candidate.is_file():
            return candidate
    raise SystemExit(f"Stopped: no backup called {name} in backups/.")


def safe_member(member: str) -> bool:
    """Only files under private/, with no way to climb out of it."""
    parts = PurePosixPath(member).parts
    return len(parts) > 1 and parts[0] == "private" and ".." not in parts and not member.startswith("/")


def as_sql(dump: Path) -> Path:
    """The dump as SQL, ready for psql. This container's Postgres client can be
    newer than the server (17 here, the server is 16); a newer pg_restore writes
    settings an older server does not know, such as transaction_timeout, which
    stop the load. Those lines are dropped; the data is untouched."""
    raw = dump.with_suffix(".raw.sql")
    run(["pg_restore", "--no-owner", "-f", str(raw), str(dump)])
    server = int(psql_value("SHOW server_version_num"))
    newer_only = ("SET transaction_timeout",) if server < 170000 else ()
    out = dump.with_suffix(".sql")
    with open(raw, encoding="utf-8") as src, open(out, "w", encoding="utf-8") as dst:
        for line in src:
            if not line.startswith(newer_only):
                dst.write(line)
    return out


def restore(name: str | None, yes: bool) -> None:
    path = resolve(name)
    with zipfile.ZipFile(path) as z:
        try:
            m = json.loads(z.read("manifest.json"))
        except KeyError:
            raise SystemExit(f"Stopped: {path.name} is not a shop backup (no manifest.json).")
        if z.testzip():
            raise SystemExit(f"Stopped: {path.name} is damaged. Nothing was changed.")
        members = [n for n in z.namelist() if safe_member(n) and not n.endswith("/")]

    say(f"Restore from: {path.name}")
    say(f"  made {m['made_utc']} (UTC)")
    say(f"  databases: {', '.join(m['databases'])}; files from private/: {len(members)}")
    say()
    say("This REPLACES " + " and ".join(m["databases"]) + " with the copies in the backup.")
    say("Everything recorded in the shop's app since that backup is replaced.")
    say("Files in the backup are put back into private/; newer files there are left alone.")
    say("A backup of what is there now is saved first, so this can be undone.")
    if not yes:
        try:
            answer = input("Type yes to restore, or anything else to stop: ")
        except EOFError:
            answer = ""
        if answer.strip().lower() != "yes":
            say("Stopped. Nothing was changed.")
            return

    say()
    if REQUIRED in existing_databases():
        say("First, saving what is there now…")
        save(label="before-restore")
    else:
        say(f"There is no {REQUIRED} database now, so there is nothing to save first.")
    say()

    admin = ["psql", "-X", "-q", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-c"]
    with tempfile.TemporaryDirectory() as tmp, zipfile.ZipFile(path) as z:
        # Each database loads into a side copy first. Only once every one has
        # loaded completely are the live ones swapped out, so a failure part
        # way leaves the shop's data exactly as it was.
        for db in m["databases"]:
            side = f"{db}_restoring"
            say(f"Loading the {db} database from the backup…")
            dump = Path(tmp) / f"{db}.dump"
            with z.open(f"{db}.dump") as src, open(dump, "wb") as dst:
                shutil.copyfileobj(src, dst)
            run(admin + [f"DROP DATABASE IF EXISTS {side} WITH (FORCE)"])
            run(admin + [f"CREATE DATABASE {side}"])
            try:
                run(["psql", "-X", "-q", "-d", side, "-v", "ON_ERROR_STOP=1", "--single-transaction",
                     "-o", os.devnull, "-f", str(as_sql(dump))])
            except SystemExit:
                run(admin + [f"DROP DATABASE IF EXISTS {side} WITH (FORCE)"])
                raise SystemExit(f"Stopped: the backup's {db} would not load. The shop's data was not changed.")

        for db in m["databases"]:
            say(f"Swapping in the restored {db}…")
            run(admin + [f"DROP DATABASE IF EXISTS {db} WITH (FORCE)"])
            run(admin + [f"ALTER DATABASE {db}_restoring RENAME TO {db}"])

        say(f"Putting back {len(members)} files in private/…")
        for member in members:
            target = REPO / PurePosixPath(member)
            target.parent.mkdir(parents=True, exist_ok=True)
            with z.open(member) as src, open(target, "wb") as dst:
                shutil.copyfileobj(src, dst)

    say()
    say(f"Restored from {path.name}. Reload the shop's screens to see it.")


def main() -> None:
    ap = argparse.ArgumentParser(description="Back up and restore the shop's data.")
    sub = ap.add_subparsers(dest="command", required=True)
    sv = sub.add_parser("save", help="Make a new backup in backups/.")
    sv.add_argument("--label", default="", help="Added to the file name, e.g. before-update.")
    sub.add_parser("list", help="List the backups, newest first.")
    r = sub.add_parser("restore", help="Put a backup back. Asks first.")
    r.add_argument("backup", nargs="?", help="The backup's file name. Leave out for the newest.")
    r.add_argument("--yes", action="store_true", help="Do not ask (the Technical workbench asks on its own screen).")
    a = ap.parse_args()
    if a.command == "save":
        save(a.label)
    elif a.command == "list":
        list_backups()
    else:
        restore(a.backup, a.yes)


if __name__ == "__main__":
    main()
