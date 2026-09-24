"""The terminal commands, runnable from the page.

Each operation is the same command the READMEs give — `python -m harness …`,
`psql -f …`, `pg_prove …` — run as a subprocess inside the review container,
with its output streamed to the screen. Nothing here reimplements the harness
or the database setup; it only saves opening a terminal to type them.

The container has what those commands need: the harness's Python packages,
the Postgres client and pg_prove, the API key from .env, and the database
at host `db` (see docker-compose.yml). Run outside that container, a missing
tool is reported, not assumed.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HARNESS = REPO / "extraction" / "harness"
SQL = REPO / "sql"
RUNS = REPO / "extraction" / "runs"


def schema_files() -> list[Path]:
    """Sections 0–14, then every numbered section file in order (15, 16, 17…).
    The same order the README gives, and the one the file headers number."""
    return [SQL / "grooming_platform_schema.sql"] + sorted(SQL.glob("[0-9][0-9]_*.sql"))


FIXTURE = SQL / "seed" / "fixture.sql"


@dataclass
class Step:
    label: str
    argv: list[str]
    cwd: Path


def _psql(*args: str) -> list[str]:
    # Connection comes from PGHOST / PGUSER / PGPASSWORD / PGDATABASE (compose sets them).
    return ["psql", "-X", "-q", *args]


def setup_database(reset: bool) -> list[Step]:
    steps = []
    if reset:
        steps.append(Step("Drop the groom schema (all app data in the test database)",
                          _psql("-v", "ON_ERROR_STOP=1", "-c", "DROP SCHEMA IF EXISTS groom CASCADE"), REPO))
    for f in schema_files():
        steps.append(Step(f"Load {f.relative_to(REPO).as_posix()}",
                          _psql("-v", "ON_ERROR_STOP=1", "-f", f.relative_to(REPO).as_posix()), REPO))
    # The README loads the fixture without ON_ERROR_STOP; so does this.
    steps.append(Step(f"Load {FIXTURE.relative_to(REPO).as_posix()}",
                      _psql("-f", FIXTURE.relative_to(REPO).as_posix()), REPO))
    return steps


def run_tests() -> list[Step]:
    tests = sorted(p.relative_to(REPO).as_posix() for p in (REPO / "tests").glob("*.sql"))
    return [Step("pg_prove tests/*.sql", ["pg_prove", *tests], REPO)]


def harness(*args: str) -> list[Step]:
    return [Step("python -m harness " + " ".join(args), [sys.executable, "-m", "harness", *args], HARNESS)]


def prompts() -> list[str]:
    return sorted(p.name for p in HARNESS.glob("prompt_*.md"))


def run_dirs() -> list[str]:
    if not RUNS.exists():
        return []
    return sorted((p.name for p in RUNS.iterdir() if p.is_dir()), reverse=True)


def stream(step: Step):
    """Yield the step's output line by line, then ('exit', code)."""
    env = {**os.environ, "PYTHONIOENCODING": "utf-8", "PYTHONUNBUFFERED": "1"}
    if shutil.which(step.argv[0]) is None and not Path(step.argv[0]).exists():
        yield f"'{step.argv[0]}' is not installed here. Run the app with `docker compose up -d` so it has " \
              "the Postgres client and pg_prove."
        yield ("exit", 127)
        return
    proc = subprocess.Popen(step.argv, cwd=step.cwd, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
    assert proc.stdout is not None
    for line in proc.stdout:
        yield line.rstrip("\n")
    yield ("exit", proc.wait())


# ------------------------------------------------------------------ status

def environment() -> dict[str, str]:
    """What this container can do, for the status panel. Never the key itself."""
    key = os.environ.get("ANTHROPIC_API_KEY") or ""
    return {
        "API key": "set" if key.strip() else "missing — add ANTHROPIC_API_KEY to .env and restart",
        "Model": os.environ.get("EXTRACTION_MODEL") or "missing — add EXTRACTION_MODEL to .env",
        "psql": "yes" if shutil.which("psql") else "no",
        "pg_prove": "yes" if shutil.which("pg_prove") else "no",
        "Database": os.environ.get("PGHOST") or "not configured",
    }


def database_state() -> str:
    """'ready', 'empty' (reachable, schema not loaded) or an error message."""
    if not shutil.which("psql"):
        return "psql is not installed here"
    try:
        out = subprocess.run(_psql("-t", "-A", "-c", "SELECT to_regclass('groom.eval_run') IS NOT NULL"),
                             capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        return "not reachable (timed out)"
    if out.returncode != 0:
        return "not reachable: " + (out.stderr.strip().splitlines() or ["unknown error"])[-1]
    return "ready" if out.stdout.strip() == "t" else "empty"
