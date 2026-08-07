#!/usr/bin/env bash
set -euo pipefail
DPM="${DPM_BIN:?DPM_BIN is required}"
PG_ADMIN="${POSTGRES_ADMIN_URL:-postgres://postgres@localhost:5432/postgres}"
CR_ADMIN="${COCKROACH_ADMIN_URL:-postgresql://root@localhost:26257/defaultdb?sslmode=disable}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifacts="$root/artifacts/failure-injection"
mkdir -p "$artifacts"

certify() {
  local engine="$1" admin="$2" target="$3" create="$4" drop="$5"
  eval "$drop" >/dev/null 2>&1 || true
  eval "$create" >/dev/null
  "$DPM" apply --source-sql "$root/fixtures/v1.sql" --target "$target" --shadow "$admin" --yes
  psql "$target" -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
INSERT INTO app.users(id, handle) VALUES ('u1', 'duplicate'), ('u2', 'duplicate');
SQL
  set +e
  "$DPM" apply --source-sql "$root/fixtures/v2.sql" --target "$target" --shadow "$admin" --yes >"$artifacts/${engine}.out" 2>"$artifacts/${engine}.err"
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "$engine injected failure unexpectedly succeeded" >&2
    exit 1
  fi
  if [[ ! -s "$artifacts/${engine}.err" ]]; then
    echo "$engine failure had no diagnostic" >&2
    exit 1
  fi
  test "$(psql "$target" -Atqc "SELECT count(*) FROM information_schema.tables WHERE table_schema='app' AND table_name='audit_log'")" = "1"
  set +e
  "$DPM" diff --source-sql "$root/fixtures/v2.sql" --target "$target" --shadow "$admin" --fail-on-diff >"$artifacts/${engine}-residual.sql" 2>&1
  residual_status=$?
  set -e
  if [[ "$residual_status" -ne 2 ]]; then
    echo "$engine residual diff expected exit 2, observed $residual_status" >&2
    exit 1
  fi
  psql "$target" -v ON_ERROR_STOP=1 -c "UPDATE app.users SET handle='unique-u2' WHERE id='u2'" >/dev/null
  "$DPM" apply --source-sql "$root/fixtures/v2.sql" --target "$target" --shadow "$admin" --yes
  "$DPM" verify --source-sql "$root/fixtures/v2.sql" --target "$target" --shadow "$admin"
  test "$(psql "$target" -Atqc "SELECT count(*) FROM app.users")" = "2"
  eval "$drop" >/dev/null 2>&1 || true
}

trap 'psql "$PG_ADMIN" -c "DROP DATABASE IF EXISTS dm_failure_pg WITH (FORCE)" >/dev/null 2>&1 || true; psql "$CR_ADMIN" -c "DROP DATABASE IF EXISTS dm_failure_cr CASCADE" >/dev/null 2>&1 || true' EXIT
certify postgres "$PG_ADMIN" "postgres://postgres@localhost:5432/dm_failure_pg"   'psql "$PG_ADMIN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE dm_failure_pg"'   'psql "$PG_ADMIN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS dm_failure_pg WITH (FORCE)"'
certify cockroach "$CR_ADMIN" "postgresql://root@localhost:26257/dm_failure_cr?sslmode=disable"   'psql "$CR_ADMIN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE dm_failure_cr"'   'psql "$CR_ADMIN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS dm_failure_cr CASCADE"'

echo "Failure-injection and recovery certification passed"
