"""One short connection per request.

The rules live in the database; this module only opens a connection the way
every caller should: the groom schema first on the path, and JIT off (the
review views stack deep enough that Postgres would spend a second compiling
a query that runs in milliseconds — see extraction/review/confirm.py).
"""
from __future__ import annotations

import os
from contextlib import contextmanager

import psycopg
from psycopg.rows import dict_row


def url() -> str:
    value = os.environ.get("DATABASE_URL")
    if not value:
        raise RuntimeError("DATABASE_URL is not set. docker-compose.yml sets it for the api service.")
    return value


@contextmanager
def connect():
    with psycopg.connect(url(), row_factory=dict_row) as conn:
        conn.execute("SET search_path = groom, public")
        conn.execute("SET jit = off")
        yield conn


def rows(sql: str, params: tuple = ()) -> list[dict]:
    with connect() as conn:
        return conn.execute(sql, params).fetchall()


def row(sql: str, params: tuple = ()) -> dict | None:
    with connect() as conn:
        return conn.execute(sql, params).fetchone()
