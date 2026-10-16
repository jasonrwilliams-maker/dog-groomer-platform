"""The shop's database brings itself up to date (api/update_database.py).

On a database of its own, built from sql/ like the shop's, and a copy of sql/
with scratch sections added: a new section goes in once and only once, a
failing one leaves the database exactly as it was and says which file, and a
database from before the list is taken to hold what it does. The tests run
in file order: each builds on what the one before left in the database.
Never touches grooming_demo and takes no backups (--skip-backup).
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlparse

import pytest

DB = "grooming_update_test"
REPO = Path(__file__).resolve().parents[2]
UPDATER = REPO / "api" / "update_database.py"


@pytest.fixture(scope="module")
def env():
    base = urlparse(os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/grooming_demo"))
    e = {**os.environ, "PGHOST": base.hostname or "localhost", "PGPORT": str(base.port or 5432),
         "PGUSER": base.username or "postgres", "PGPASSWORD": base.password or ""}
    subprocess.run(["sh", "api/load_demo.sh", "--fresh", DB], cwd=REPO, env=e, check=True,
                   stdout=subprocess.DEVNULL)
    return e


@pytest.fixture()
def sql_dir():
    d = Path(tempfile.mkdtemp(prefix="sections-"))
    for f in (REPO / "sql").glob("*.sql"):
        shutil.copy(f, d / f.name)
    yield d
    shutil.rmtree(d)


def sql(env, query: str) -> str:
    out = subprocess.run(["psql", "-X", "-q", "-t", "-A", "-d", DB, "-c", query],
                         env=env, capture_output=True, text=True, check=True)
    return out.stdout.strip()


def update(env, sql_dir: Path) -> str:
    out = subprocess.run([sys.executable, str(UPDATER), "--skip-backup", "--sql-dir", str(sql_dir), DB],
                         env=env, capture_output=True, text=True, check=True)
    return out.stdout


def test_a_fresh_build_lists_every_section_and_needs_nothing(env):
    files = 1 + len(list((REPO / "sql").glob("[0-9][0-9]_*.sql")))
    assert sql(env, "SELECT count(*) FROM upkeep.applied_section WHERE how = 'built'") == str(files)
    assert "is up to date" in update(env, REPO / "sql")


def test_a_new_section_goes_in_once(env, sql_dir):
    # Not IF NOT EXISTS: running it a second time would fail, so a second
    # update passing proves it was not run again.
    (sql_dir / "98_scratch_ok.sql").write_text(
        "SET search_path = groom, public;\nCREATE TABLE scratch_ok (id integer);\n")
    said = update(env, sql_dir)
    assert "Added 98_scratch_ok.sql" in said
    assert sql(env, "SELECT to_regclass('groom.scratch_ok') IS NOT NULL") == "t"
    assert sql(env, "SELECT how FROM upkeep.applied_section WHERE file = '98_scratch_ok.sql'") == "update"
    assert sql(env, "SELECT ok FROM upkeep.update_status") == "t"

    said = update(env, sql_dir)
    assert "is up to date" in said
    assert sql(env, "SELECT count(*) FROM upkeep.applied_section WHERE file = '98_scratch_ok.sql'") == "1"


def test_a_failing_section_changes_nothing_and_says_which(env, sql_dir):
    (sql_dir / "98_scratch_ok.sql").write_text("SELECT 1;\n")   # listed by the test above
    (sql_dir / "99_scratch_bad.sql").write_text(
        "SET search_path = groom, public;\nCREATE TABLE scratch_half (id integer);\nSELECT 1/0;\n")
    said = update(env, sql_dir)
    assert "99_scratch_bad.sql could not be added" in said
    # The table made before the error was rolled back with it, and nothing is listed.
    assert sql(env, "SELECT to_regclass('groom.scratch_half') IS NULL") == "t"
    assert sql(env, "SELECT count(*) FROM upkeep.applied_section WHERE file = '99_scratch_bad.sql'") == "0"
    assert sql(env, "SELECT ok, failed_file FROM upkeep.update_status") == "f|99_scratch_bad.sql"
    assert "division by zero" in sql(env, "SELECT message FROM upkeep.update_status")

    # Put right, the next start adds it and the failure clears.
    (sql_dir / "99_scratch_bad.sql").write_text("SELECT 1;\n")
    assert "Added 99_scratch_bad.sql" in update(env, sql_dir)
    assert sql(env, "SELECT ok FROM upkeep.update_status") == "t"


def test_a_database_from_before_the_list_is_taken_as_it_is(env, sql_dir):
    # As the shop's database was: no list, every section up to 34 in it.
    sql(env, "DROP SCHEMA upkeep CASCADE")
    (sql_dir / "98_scratch_new.sql").write_text(
        "SET search_path = groom, public;\nCREATE TABLE scratch_new (id integer);\n")
    said = update(env, sql_dir)
    assert "predates the list" in said
    assert "Added 98_scratch_new.sql" in said
    assert sql(env, "SELECT how FROM upkeep.applied_section WHERE file = '34_staff.sql'") == "baseline"
    assert sql(env, "SELECT to_regclass('groom.scratch_new') IS NOT NULL") == "t"


def test_admin_shows_a_failed_update(env):
    sql(env, "UPDATE upkeep.update_status SET ok = false, failed_file = '99_x.sql', backup = 'backups/b.zip'")
    old = os.environ.get("DATABASE_URL")
    os.environ["DATABASE_URL"] = f"postgresql://{env['PGUSER']}:{env['PGPASSWORD']}@{env['PGHOST']}:{env['PGPORT']}/{DB}"
    try:
        from app.main import database_update
        got = database_update()
    finally:
        if old is not None:
            os.environ["DATABASE_URL"] = old
    assert got["ok"] is False and got["failed_file"] == "99_x.sql" and got["backup"] == "backups/b.zip"
