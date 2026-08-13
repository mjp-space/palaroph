#!/usr/bin/env bash
# Full test run: migrations from scratch, SQL suite, then concurrency.
# Exit non-zero on any failure so CI can gate on it.
set -uo pipefail
cd "$(dirname "$0")/.."
export PGHOST=${PGHOST:-/tmp/pgrun} PGPORT=${PGPORT:-5433} PGUSER=${PGUSER:-postgres}
export PGPASSWORD=${PGPASSWORD:-}
DB=${DB:-palaro}

echo "▸ applying migrations to $DB"
dropdb --if-exists $DB 2>/dev/null; createdb $DB
for f in supabase/migrations/*.sql; do
  psql -q -d $DB -v ON_ERROR_STOP=1 -f "$f" >/dev/null || { echo "MIGRATION FAILED: $f"; exit 1; }
  echo "  ✓ $(basename "$f")"
done

echo
echo "▸ suite.sql"
out=$(psql -q -d $DB -f tests/suite.sql 2>&1)
echo "$out" | grep -E '^ (PASS|FAIL)' || true
sql_fail=$(echo "$out" | grep -cE '^ FAIL')
sql_total=$(echo "$out" | grep -cE '^ (PASS|FAIL)')
echo "  → $((sql_total - sql_fail))/$sql_total"

echo
echo "▸ resolution.sql"
rout=$(psql -q -d $DB -f tests/resolution.sql 2>&1)
echo "$rout" | grep -E '^ FAIL' || true
res_fail=$(echo "$rout" | grep -cE '^ FAIL')
res_total=$(echo "$rout" | grep -cE '^ (PASS|FAIL)')
echo "  → $((res_total - res_fail))/$res_total"

echo
echo "▸ privileges.sql"
pout=$(psql -q -d $DB -f tests/privileges.sql 2>&1)
echo "$pout" | grep -E '^ FAIL' || true
priv_fail=$(echo "$pout" | grep -cE '^ FAIL')
priv_total=$(echo "$pout" | grep -cE '^ (PASS|FAIL)')
echo "  → $((priv_total - priv_fail))/$priv_total"

echo
echo "▸ concurrency.sh"
./tests/concurrency.sh
conc=$?

echo
if [ "$sql_fail" -eq 0 ] && [ "$res_fail" -eq 0 ] && [ "$priv_fail" -eq 0 ] && [ "$conc" -eq 0 ]; then
  echo "ALL GREEN — $sql_total core + $res_total resolution + $priv_total privilege + 9 concurrency"
  exit 0
else
  echo "FAILURES PRESENT"
  exit 1
fi
