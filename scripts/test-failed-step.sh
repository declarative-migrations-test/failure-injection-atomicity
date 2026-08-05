#!/usr/bin/env bash
set -euo pipefail
DPM="${DPM_BIN:?DPM_BIN is required}"
PG_ADMIN="${POSTGRES_ADMIN_URL:-postgres://postgres@localhost:5432/postgres}"
CR_ADMIN="${COCKROACH_ADMIN_URL:-postgresql://root@localhost:26257/defaultdb?sslmode=disable}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifacts="$root/artifacts"
mkdir -p "$artifacts"

certify() {
  local engine="$1" admin="$2" target="$3" create_sql="$4" drop_sql="$5"
  eval "$drop_sql" >/dev/null 2>&1 || true
  eval "$create_sql" >/dev/null

  "$DPM" apply --source-sql "$root/fixtures/v1.sql" --target "$target" --shadow "$admin" --yes
  psql "$target" -v ON_ERROR_STOP=1 -c "INSERT INTO app.users(id,handle) VALUES ('u1','duplicate'),('u2','duplicate')" >/dev/null

  set +e
  "$DPM" apply --source-sql "$root/fixtures/v2.sql" --target "$target" --shadow "$admin" --yes >"$artifacts/${engine}-failed.out" 2>"$artifacts/${engine}-failed.err"
  apply_status=$?
  set -e
  [[ "$apply_status" -ne 0 ]] || { echo "$engine injected failure unexpectedly succeeded" >&2; exit 1; }
  [[ -s "$artifacts/${engine}-failed.err" ]] || { echo "$engine failure produced no diagnostic" >&2; exit 1; }
  if grep -Eqi 'panicked at|stack backtrace|segmentation fault' "$artifacts/${engine}-failed.err"; then
    echo "$engine failure crashed instead of returning an error" >&2
    exit 1
  fi

  [[ "$(psql "$target" -Atqc "SELECT count(*) FROM app.users")" == "2" ]]
  [[ "$(psql "$target" -Atqc "SELECT count(*) FROM information_schema.table_constraints WHERE table_schema='app' AND table_name='users' AND constraint_name='users_handle_key'")" == "0" ]]
  audit_table="$(psql "$target" -Atqc "SELECT count(*) FROM information_schema.tables WHERE table_schema='app' AND table_name='audit_log'")"
  printf 'audit_log_after_failure=%s\n' "$audit_table" >"$artifacts/${engine}-catalog-state.txt"
  if [[ "$engine" == "postgres" && "$audit_table" != "0" ]]; then
    echo "PostgreSQL transaction did not roll back the earlier table create" >&2
    exit 1
  fi

  set +e
  "$DPM" diff --source-sql "$root/fixtures/v2.sql" --target "$target" --shadow "$admin" --fail-on-diff >"$artifacts/${engine}-residual.sql" 2>&1
  diff_status=$?
  set -e
  [[ "$diff_status" -eq 2 ]] || { echo "$engine residual diff expected exit 2, observed $diff_status" >&2; exit 1; }
  grep -Eqi 'users_handle_key|audit_log|ADD CONSTRAINT|CREATE TABLE' "$artifacts/${engine}-residual.sql"

  psql "$target" -v ON_ERROR_STOP=1 -c "UPDATE app.users SET handle='unique-u2' WHERE id='u2'" >/dev/null
  "$DPM" apply --source-sql "$root/fixtures/v2.sql" --target "$target" --shadow "$admin" --yes
  "$DPM" diff --source-sql "$root/fixtures/v2.sql" --target "$target" --shadow "$admin" --fail-on-diff >/dev/null
  "$DPM" verify --source-sql "$root/fixtures/v2.sql" --target "$target" --shadow "$admin"

  [[ "$(psql "$target" -Atqc "SELECT count(*) FROM app.users")" == "2" ]]
  [[ "$(psql "$target" -Atqc "SELECT count(*) FROM information_schema.tables WHERE table_schema='app' AND table_name='audit_log'")" == "1" ]]
  [[ "$(psql "$target" -Atqc "SELECT count(*) FROM information_schema.table_constraints WHERE table_schema='app' AND table_name='users' AND constraint_name='users_handle_key'")" == "1" ]]
  eval "$drop_sql" >/dev/null 2>&1 || true
}

trap 'psql "$PG_ADMIN" -c "DROP DATABASE IF EXISTS dm_failed_step_pg WITH (FORCE)" >/dev/null 2>&1 || true; psql "$CR_ADMIN" -c "DROP DATABASE IF EXISTS dm_failed_step_cr CASCADE" >/dev/null 2>&1 || true' EXIT
certify postgres "$PG_ADMIN" "postgres://postgres@localhost:5432/dm_failed_step_pg" \
  'psql "$PG_ADMIN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE dm_failed_step_pg"' \
  'psql "$PG_ADMIN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS dm_failed_step_pg WITH (FORCE)"'
certify cockroach "$CR_ADMIN" "postgresql://root@localhost:26257/dm_failed_step_cr?sslmode=disable" \
  'psql "$CR_ADMIN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE dm_failed_step_cr"' \
  'psql "$CR_ADMIN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS dm_failed_step_cr CASCADE"'

echo "Failed-step recovery certification passed"
