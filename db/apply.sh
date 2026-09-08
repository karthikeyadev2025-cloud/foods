#!/usr/bin/env bash
# Apply every migration in dependency order, then run the DB acceptance tests.
#
#   psql "$DATABASE_URL" -f db/local/supabase_stub.sql     # once, on an empty database
#   DATABASE_URL=postgresql://... db/apply.sh
#
# Run the stub first. It gives a plain Postgres the two things Supabase has that
# decide whether this code actually works: auth.uid(), and pgcrypto and pg_trgm in
# an `extensions` schema rather than in public. Without it every bug of the form
# "works here, function does not exist on Supabase" is invisible — which is how
# issue_license() shipped broken past a green test run.
#
# Order matters: 03_rls.sql enables policies on tables that 04_extended.sql
# creates, so 04 must run before 03. Each file runs in its own transaction.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DATABASE_URL:?set DATABASE_URL to the Postgres connection string}"

MIGRATIONS=(
  db/01_schema.sql
  db/02_logic.sql
  db/04_extended.sql
  db/03_rls.sql
)
for f in db/0[5-9]_*.sql db/[1-9][0-9]_*.sql; do
  [ -e "$f" ] && MIGRATIONS+=("$f")
done

for f in "${MIGRATIONS[@]}"; do
  echo "==> $f"
  psql "$DATABASE_URL" -q -v ON_ERROR_STOP=1 -1 -f "$f"
done

for t in db/tests/*.sql; do
  echo "==> test $t"
  psql "$DATABASE_URL" -q -v ON_ERROR_STOP=1 -f "$t"
done

echo "done"
