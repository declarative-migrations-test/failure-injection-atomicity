#!/usr/bin/env bash
set -euo pipefail

DPM="${DPM_BIN:?DPM_BIN is required}"
PG_ADMIN="${POSTGRES_ADMIN_URL:-postgres://postgres@localhost:5432/postgres}"
CR_ADMIN="${COCKROACH_ADMIN_URL:-postgresql://root@localhost:26257/defaultdb?sslmode=disable}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifacts="$root/artifacts/failure-injection"
mkdir -p "$artifacts"

scalar() {
  local target="$1" query="$2"
  psql "$target" -Atq -v ON_ERROR_STOP=1 -c "$query"
}

certify() {
  local engine="$1" admin="$2" target="$3" create="$4" drop="$5"
  local prefix="$artifacts/${engine}"

  eval "$drop" >/dev/null 2>&1 || true
  eval "$create" >/dev/null

  "$DPM" apply \
    --source-sql "$root/fixtures/v1.sql" \
    --target "$target" \
    --shadow "$admin" \
    --yes \
    >"${prefix}-baseline-apply.out"
  "$DPM" verify \
    --source-sql "$root/fixtures/v1.sql" \
    --target "$target" \
    --shadow "$admin" \
    >"${prefix}-baseline-verify.out"

  psql "$target" -v ON_ERROR_STOP=1 <<'SQL' >"${prefix}-seed.out"
INSERT INTO app.users(id, handle)
VALUES ('u1', 'duplicate'), ('u2', 'duplicate');
SQL

  set +e
  "$DPM" diff \
    --source-sql "$root/fixtures/v2.sql" \
    --target "$target" \
    --shadow "$admin" \
    --fail-on-diff \
    >"${prefix}-fault-plan.sql" \
    2>"${prefix}-fault-plan.err"
  local plan_status=$?
  set -e
  if [[ "$plan_status" -ne 2 ]]; then
    echo "$engine fault plan expected exit 2, observed $plan_status" >&2
    exit 1
  fi
  if ! grep -Eqi 'audit_log' "${prefix}-fault-plan.sql" "${prefix}-fault-plan.err"; then
    echo "$engine fault plan omitted audit_log" >&2
    exit 1
  fi
  if ! grep -Eqi 'users_handle_key|unique.*handle' "${prefix}-fault-plan.sql" "${prefix}-fault-plan.err"; then
    echo "$engine fault plan omitted the late unique constraint" >&2
    exit 1
  fi

  set +e
  "$DPM" apply \
    --source-sql "$root/fixtures/v2.sql" \
    --target "$target" \
    --shadow "$admin" \
    --yes \
    >"${prefix}-fault-apply.out" \
    2>"${prefix}-fault-apply.err"
  local status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "$engine injected failure unexpectedly succeeded" >&2
    exit 1
  fi
  if [[ ! -s "${prefix}-fault-apply.err" && ! -s "${prefix}-fault-apply.out" ]]; then
    echo "$engine failure had no diagnostic" >&2
    exit 1
  fi
  if grep -Eqi 'panicked at|stack backtrace|segmentation fault|memory safety' \
    "${prefix}-fault-apply.err" "${prefix}-fault-apply.out"; then
    echo "$engine migration crashed instead of returning a bounded error" >&2
    exit 1
  fi
  if ! grep -Eqi 'unique|duplicate|users_handle_key' \
    "${prefix}-fault-apply.err" "${prefix}-fault-apply.out"; then
    echo "$engine failure diagnostic did not identify the injected uniqueness conflict" >&2
    exit 1
  fi

  local users_after_failure audit_after_failure unique_after_failure
  users_after_failure="$(scalar "$target" "SELECT count(*) FROM app.users")"
  audit_after_failure="$(scalar "$target" "SELECT count(*) FROM information_schema.tables WHERE table_schema='app' AND table_name='audit_log'")"
  unique_after_failure="$(scalar "$target" "SELECT count(*) FROM information_schema.table_constraints WHERE table_schema='app' AND table_name='users' AND constraint_name='users_handle_key'")"
  test "$users_after_failure" = "2"
  test "$unique_after_failure" = "0"

  # PostgreSQL rolls the full failed DDL transaction back. CockroachDB's online
  # schema-change machinery preserves the earlier table creation while rejecting
  # the later uniqueness backfill. Both outcomes must be explicit and recoverable.
  case "$engine" in
    postgres)
      test "$audit_after_failure" = "0"
      ;;
    cockroach)
      test "$audit_after_failure" = "1"
      ;;
    *)
      echo "unsupported engine: $engine" >&2
      exit 1
      ;;
  esac

  set +e
  "$DPM" diff \
    --source-sql "$root/fixtures/v2.sql" \
    --target "$target" \
    --shadow "$admin" \
    --fail-on-diff \
    >"${prefix}-residual.sql" \
    2>"${prefix}-residual.err"
  local residual_status=$?
  set -e
  if [[ "$residual_status" -ne 2 ]]; then
    echo "$engine residual diff expected exit 2, observed $residual_status" >&2
    exit 1
  fi
  if ! grep -Eqi 'users_handle_key|unique.*handle' \
    "${prefix}-residual.sql" "${prefix}-residual.err"; then
    echo "$engine residual diff omitted the unresolved uniqueness work" >&2
    exit 1
  fi

  if [[ "$engine" == "postgres" ]]; then
    if ! grep -Fqi -- '-- create table: app.audit_log' \
      "${prefix}-residual.sql" "${prefix}-residual.err"; then
      echo "PostgreSQL residual diff omitted the rolled-back audit_log table" >&2
      exit 1
    fi
  else
    if grep -Fqi -- '-- create table: app.audit_log' \
      "${prefix}-residual.sql" "${prefix}-residual.err"; then
      echo "CockroachDB residual diff tried to recreate the preserved audit_log table" >&2
      exit 1
    fi
    if ! grep -Eqi 'audit_log_user_id_fkey|foreign key.*audit_log' \
      "${prefix}-residual.sql" "${prefix}-residual.err"; then
      echo "CockroachDB residual diff omitted the unfinished audit_log foreign key" >&2
      exit 1
    fi
  fi

  psql "$target" -v ON_ERROR_STOP=1 \
    -c "UPDATE app.users SET handle='unique-u2' WHERE id='u2'" \
    >"${prefix}-repair-data.out"

  "$DPM" apply \
    --source-sql "$root/fixtures/v2.sql" \
    --target "$target" \
    --shadow "$admin" \
    --yes \
    >"${prefix}-recovery-apply.out"
  "$DPM" diff \
    --source-sql "$root/fixtures/v2.sql" \
    --target "$target" \
    --shadow "$admin" \
    --fail-on-diff \
    >"${prefix}-recovery-diff.sql"
  "$DPM" verify \
    --source-sql "$root/fixtures/v2.sql" \
    --target "$target" \
    --shadow "$admin" \
    >"${prefix}-recovery-verify.out"

  test "$(scalar "$target" "SELECT count(*) FROM app.users")" = "2"
  test "$(scalar "$target" "SELECT count(*) FROM information_schema.tables WHERE table_schema='app' AND table_name='audit_log'")" = "1"
  test "$(scalar "$target" "SELECT count(*) FROM information_schema.table_constraints WHERE table_schema='app' AND table_name='users' AND constraint_name='users_handle_key'")" = "1"

  printf '%s\n' \
    "engine=${engine}" \
    "failed_apply_status=${status}" \
    "users_preserved=${users_after_failure}" \
    "audit_log_after_failure=${audit_after_failure}" \
    "unique_constraint_after_failure=${unique_after_failure}" \
    "recovery_converged=true" \
    >"${prefix}-summary.txt"

  eval "$drop" >/dev/null 2>&1 || true
}

trap 'psql "$PG_ADMIN" -c "DROP DATABASE IF EXISTS dm_failure_pg WITH (FORCE)" >/dev/null 2>&1 || true; psql "$CR_ADMIN" -c "DROP DATABASE IF EXISTS dm_failure_cr CASCADE" >/dev/null 2>&1 || true' EXIT

certify \
  postgres \
  "$PG_ADMIN" \
  "postgres://postgres@localhost:5432/dm_failure_pg" \
  'psql "$PG_ADMIN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE dm_failure_pg"' \
  'psql "$PG_ADMIN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS dm_failure_pg WITH (FORCE)"'

certify \
  cockroach \
  "$CR_ADMIN" \
  "postgresql://root@localhost:26257/dm_failure_cr?sslmode=disable" \
  'psql "$CR_ADMIN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE dm_failure_cr"' \
  'psql "$CR_ADMIN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS dm_failure_cr CASCADE"'

echo "Failure-injection engine-specific rollback and recovery certification passed"
