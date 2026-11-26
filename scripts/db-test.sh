#!/usr/bin/env bash
# Applies stubs + all migrations to a fresh database and runs supabase/tests/*.sql.
# Usage: PGHOST=localhost PGPORT=54329 PGUSER=postgres PGPASSWORD=local scripts/db-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB="moma_test_$$"
psql -v ON_ERROR_STOP=1 -q -d postgres -c "create database $DB"
trap 'psql -q -d postgres -c "drop database if exists $DB" >/dev/null 2>&1 || true' EXIT
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f supabase/tests/stubs.sql
for f in supabase/migrations/*.sql; do
  echo "migration: $f"
  psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$f"
done
for f in supabase/tests/[0-9]*.sql; do
  echo "test: $f"
  psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$f"
done
