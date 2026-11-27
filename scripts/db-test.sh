#!/usr/bin/env bash
# Applies stubs + all migrations to a fresh database and runs supabase/tests/*.sql.
# Usage: PGHOST=localhost PGPORT=54329 PGUSER=postgres PGPASSWORD=local scripts/db-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
fresh_db() { # $1 = name; creates a database with stubs + every migration
  local f
  psql -v ON_ERROR_STOP=1 -q -d postgres -c "create database $1"
  psql -v ON_ERROR_STOP=1 -q -d "$1" -f supabase/tests/stubs.sql
  for f in supabase/migrations/*.sql; do
    echo "migration: $f"
    psql -v ON_ERROR_STOP=1 -q -d "$1" -f "$f"
  done
}
DB="moma_test_$$"
ISO="moma_iso_$$"
trap 'psql -q -d postgres -c "drop database if exists $DB" >/dev/null 2>&1 || true; psql -q -d postgres -c "drop database if exists $ISO" >/dev/null 2>&1 || true' EXIT
fresh_db "$DB"
for f in supabase/tests/[0-9]*.sql; do
  echo "test: $f"
  psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$f"
done
# Suites that need an unbound owner singleton run on their own fresh database.
for f in supabase/tests/isolated/*.sql; do
  [ -e "$f" ] || continue
  fresh_db "$ISO" >/dev/null
  echo "test (isolated): $f"
  psql -v ON_ERROR_STOP=1 -q -d "$ISO" -f "$f"
  psql -q -d postgres -c "drop database $ISO" >/dev/null
done
