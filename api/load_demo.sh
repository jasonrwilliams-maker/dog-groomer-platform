#!/bin/sh
# Build a database from the schema and the demo dogs.
#
#   load_demo.sh             build grooming_demo if it does not exist yet
#   load_demo.sh --fresh DB  drop DB and build it again (the tests use this)
#
# Run from the repo root (the compose service mounts it at /repo). The
# connection comes from PGHOST / PGUSER / PGPASSWORD, as for psql.
set -eu

DB=grooming_demo
FRESH=no
if [ "${1:-}" = "--fresh" ]; then FRESH=yes; DB=${2:?usage: load_demo.sh --fresh DBNAME}; fi

exists=$(psql -X -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB'")
if [ "$FRESH" = no ] && [ "$exists" = 1 ]; then
    echo "$DB already exists — leaving it as it is."
    exit 0
fi

psql -X -q -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)"
psql -X -q -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE $DB"
for f in sql/grooming_platform_schema.sql $(ls sql/[0-9][0-9]_*.sql | sort) sql/seed/demo.sql; do
    psql -X -q -d "$DB" -v ON_ERROR_STOP=1 -f "$f" >/dev/null
done
echo "$DB built from the schema and sql/seed/demo.sql."
