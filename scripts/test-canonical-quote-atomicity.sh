#!/usr/bin/env bash
set -euo pipefail

DPM="${DPM_BIN:?DPM_BIN is required}"
API_DIR="${CANONICAL_API_DIR:?CANONICAL_API_DIR is required}"
ADMIN="${POSTGRES_ADMIN_URL:-postgres://postgres:quote-atomicity@localhost:5432/postgres}"
PG_MAJOR="${POSTGRES_MAJOR:?POSTGRES_MAJOR is required}"
ROLE_PASSWORD="${TEST_ROLE_PASSWORD:-quote-atomicity}"

if [[ ! "$PG_MAJOR" =~ ^(17|18)$ ]]; then
  echo "unsupported PostgreSQL test major: $PG_MAJOR" >&2
  exit 1
fi

DB="canonical_quote_atomicity_pg${PG_MAJOR}"
TARGET_ADMIN="postgres://postgres:${ROLE_PASSWORD}@localhost:5432/${DB}"
MIGRATOR="postgres://canonical_cloud__quote__migrator:${ROLE_PASSWORD}@localhost:5432/${DB}"
API_RUNTIME="postgres://canonical_cloud__quote__api_rw:${ROLE_PASSWORD}@localhost:5432/${DB}"
WEB_RUNTIME="postgres://canonical_cloud__quote__web_ro:${ROLE_PASSWORD}@localhost:5432/${DB}"
SCHEMA="$API_DIR/db/schema.sql"
BOOTSTRAP="$API_DIR/db/bootstrap.sql"
GRANTS="$API_DIR/db/grants.sql"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="$ROOT/artifacts/canonical-quote-atomicity/pg${PG_MAJOR}"
FAULTY_SCHEMA="$ARTIFACTS/faulty-schema.sql"
mkdir -p "$ARTIFACTS"

for required in "$SCHEMA" "$BOOTSTRAP" "$GRANTS"; do
  if [[ ! -f "$required" ]]; then
    echo "missing Canonical database source: $required" >&2
    exit 1
  fi
done

cleanup() {
  psql "$ADMIN" -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS ${DB} WITH (FORCE)" >/dev/null 2>&1 || true
  for role in \
    canonical_cloud__quote__web_ro \
    canonical_cloud__quote__api_rw \
    canonical_cloud__quote__migrator
  do
    psql "$ADMIN" -v ON_ERROR_STOP=1 \
      -c "DROP ROLE IF EXISTS ${role}" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT
cleanup

psql "$ADMIN" -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE ${DB}" >/dev/null
psql "$TARGET_ADMIN" -v ON_ERROR_STOP=1 \
  -f "$BOOTSTRAP" >"$ARTIFACTS/bootstrap.out"
psql "$TARGET_ADMIN" -v ON_ERROR_STOP=1 -v role_password="$ROLE_PASSWORD" \
  >"$ARTIFACTS/test-role-passwords.out" <<'SQL'
ALTER ROLE canonical_cloud__quote__migrator PASSWORD :'role_password';
ALTER ROLE canonical_cloud__quote__api_rw PASSWORD :'role_password';
ALTER ROLE canonical_cloud__quote__web_ro PASSWORD :'role_password';
SQL

"$DPM" apply \
  --source-sql "$SCHEMA" \
  --target "$MIGRATOR" \
  --shadow "$ADMIN" \
  --yes \
  >"$ARTIFACTS/baseline-apply.out"
psql "$TARGET_ADMIN" -v ON_ERROR_STOP=1 \
  -f "$GRANTS" >"$ARTIFACTS/baseline-grants.out"
"$DPM" diff \
  --source-sql "$SCHEMA" \
  --target "$MIGRATOR" \
  --shadow "$ADMIN" \
  --fail-on-diff \
  >"$ARTIFACTS/baseline-diff.sql"
"$DPM" verify \
  --source-sql "$SCHEMA" \
  --target "$MIGRATOR" \
  --shadow "$ADMIN" \
  >"$ARTIFACTS/baseline-verify.out"

psql "$API_RUNTIME" -v ON_ERROR_STOP=1 >"$ARTIFACTS/seed.out" <<'SQL'
BEGIN;
SET LOCAL app.current_subject = 'atomicity-owner';
INSERT INTO canonical_cloud__quote.canonical_context (
  id, owner_subject, name, context_markdown, context_json
) VALUES (
  '11111111-1111-4111-8111-111111111111',
  'atomicity-owner',
  'Atomicity fixture',
  '# Synthetic atomicity context',
  '{"environment":"test","contains_secrets":false}'::jsonb
);
INSERT INTO canonical_cloud__quote.canonical_quote (
  id,
  owner_subject,
  context_record_id,
  request_json,
  application_context_markdown,
  context_snapshot_markdown,
  context_snapshot_json,
  gemini_model,
  status
) VALUES
(
  '22222222-2222-4222-8222-222222222221',
  'atomicity-owner',
  '11111111-1111-4111-8111-111111111111',
  '{"organizationName":"Atomicity Fixture A","contactName":"Test Operator","contactEmail":"a@example.invalid","employeeCount":42,"frameworks":["soc2_type_2"],"currentStage":"readiness","infrastructure":["aws"],"dataSensitivity":["confidential"],"hasSecurityProgram":true,"hasPolicies":true,"hasRiskAssessment":false,"hasIncidentResponsePlan":true,"hasVendorManagement":false,"answersVersion":1}'::jsonb,
  '# Synthetic application policy',
  '# Synthetic atomicity context',
  '{"environment":"test","contains_secrets":false}'::jsonb,
  'gemini-3.6-pro',
  'queued'
),
(
  '22222222-2222-4222-8222-222222222222',
  'atomicity-owner',
  '11111111-1111-4111-8111-111111111111',
  '{"organizationName":"Atomicity Fixture B","contactName":"Test Operator","contactEmail":"b@example.invalid","employeeCount":84,"frameworks":["nist_800_53"],"currentStage":"readiness","infrastructure":["gcp"],"dataSensitivity":["confidential"],"hasSecurityProgram":true,"hasPolicies":true,"hasRiskAssessment":true,"hasIncidentResponsePlan":true,"hasVendorManagement":false,"answersVersion":1}'::jsonb,
  '# Synthetic application policy',
  '# Synthetic atomicity context',
  '{"environment":"test","contains_secrets":false}'::jsonb,
  'gemini-3.6-pro',
  'queued'
);
COMMIT;
SQL

python3 - "$SCHEMA" "$FAULTY_SCHEMA" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
needle = "    analysis_json jsonb,\n    error_code text CHECK ("
replacement = (
    "    analysis_json jsonb,\n"
    "    atomicity_probe text NOT NULL DEFAULT 'duplicate',\n"
    "    error_code text CHECK ("
)
if source.count(needle) != 1:
    raise SystemExit("could not locate the canonical_quote insertion point")
faulty = source.replace(needle, replacement, 1)
faulty += """

CREATE UNIQUE INDEX canonical_quote_atomicity_probe_unique
    ON canonical_cloud__quote.canonical_quote (atomicity_probe);
"""
Path(sys.argv[2]).write_text(faulty)
PY

set +e
"$DPM" diff \
  --source-sql "$FAULTY_SCHEMA" \
  --target "$MIGRATOR" \
  --shadow "$ADMIN" \
  --fail-on-diff \
  >"$ARTIFACTS/faulty-plan.sql" \
  2>"$ARTIFACTS/faulty-plan.err"
plan_status=$?
set -e
if [[ "$plan_status" -ne 2 ]]; then
  echo "faulty candidate diff expected exit 2, observed $plan_status" >&2
  exit 1
fi

python3 - "$ARTIFACTS/faulty-plan.sql" "$ARTIFACTS/faulty-plan.err" <<'PY'
from pathlib import Path
import sys

plan = "\n".join(Path(path).read_text() for path in sys.argv[1:]).lower()
column_markers = ["add column", "atomicity_probe"]
if not all(marker in plan for marker in column_markers):
    raise SystemExit("faulty plan omits the additive probe column")
if "canonical_quote_atomicity_probe_unique" not in plan:
    raise SystemExit("faulty plan omits the late unique-index failure")
column_position = plan.find("add column")
index_position = plan.find("canonical_quote_atomicity_probe_unique")
if column_position < 0 or index_position <= column_position:
    raise SystemExit("faulty plan does not order the probe column before the failing index")
PY

set +e
"$DPM" apply \
  --source-sql "$FAULTY_SCHEMA" \
  --target "$MIGRATOR" \
  --shadow "$ADMIN" \
  --yes \
  >"$ARTIFACTS/faulty-apply.out" \
  2>"$ARTIFACTS/faulty-apply.err"
fault_status=$?
set -e
if [[ "$fault_status" -eq 0 ]]; then
  echo "late unique-index failure unexpectedly succeeded" >&2
  exit 1
fi
if [[ ! -s "$ARTIFACTS/faulty-apply.err" && ! -s "$ARTIFACTS/faulty-apply.out" ]]; then
  echo "failed Canonical migration produced no diagnostic" >&2
  exit 1
fi
if grep -Eqi 'panicked at|stack backtrace|segmentation fault|memory safety' \
  "$ARTIFACTS/faulty-apply.err" "$ARTIFACTS/faulty-apply.out"; then
  echo "failed Canonical migration crashed instead of returning an error" >&2
  exit 1
fi

grep -Eqi 'unique|duplicate|canonical_quote_atomicity_probe_unique' \
  "$ARTIFACTS/faulty-apply.err" "$ARTIFACTS/faulty-apply.out"

assert_scalar() {
  local expected="$1" query="$2" observed
  observed="$(psql "$TARGET_ADMIN" -Atq -v ON_ERROR_STOP=1 -c "$query")"
  if [[ "$observed" != "$expected" ]]; then
    echo "atomicity assertion failed: expected $expected, observed $observed" >&2
    echo "query: $query" >&2
    exit 1
  fi
}

# The column was planned before the unique index. A transactionally atomic apply
# must roll both changes back when duplicate existing rows reject the index.
assert_scalar 0 "SELECT count(*) FROM information_schema.columns WHERE table_schema='canonical_cloud__quote' AND table_name='canonical_quote' AND column_name='atomicity_probe'"
assert_scalar 0 "SELECT count(*) FROM pg_indexes WHERE schemaname='canonical_cloud__quote' AND indexname='canonical_quote_atomicity_probe_unique'"
assert_scalar 2 "SELECT count(*) FROM canonical_cloud__quote.canonical_quote WHERE owner_subject='atomicity-owner'"
assert_scalar 4 "SELECT count(*) FROM pg_policies WHERE schemaname='canonical_cloud__quote' AND tablename IN ('canonical_context','canonical_quote','canonical_quote_event','canonical_model_attempt')"
assert_scalar 4 "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='canonical_cloud__quote' AND c.relname IN ('canonical_context','canonical_quote','canonical_quote_event','canonical_model_attempt') AND c.relrowsecurity AND c.relforcerowsecurity"

# The failed apply must release its lock and leave the reviewed production source
# as a no-op. This retry is intentionally non-destructive.
"$DPM" apply \
  --source-sql "$SCHEMA" \
  --target "$MIGRATOR" \
  --shadow "$ADMIN" \
  --yes \
  >"$ARTIFACTS/recovery-apply.out"
psql "$TARGET_ADMIN" -v ON_ERROR_STOP=1 \
  -f "$GRANTS" >"$ARTIFACTS/recovery-grants.out"
"$DPM" diff \
  --source-sql "$SCHEMA" \
  --target "$MIGRATOR" \
  --shadow "$ADMIN" \
  --fail-on-diff \
  >"$ARTIFACTS/recovery-diff.sql"
"$DPM" verify \
  --source-sql "$SCHEMA" \
  --target "$MIGRATOR" \
  --shadow "$ADMIN" \
  >"$ARTIFACTS/recovery-verify.out"

assert_scalar 2 "SELECT count(*) FROM canonical_cloud__quote.canonical_quote WHERE owner_subject='atomicity-owner'"
assert_scalar 0 "SELECT count(*) FROM pg_roles WHERE rolname IN ('canonical_cloud__quote__migrator','canonical_cloud__quote__api_rw','canonical_cloud__quote__web_ro') AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)"
assert_scalar f "SELECT has_table_privilege('canonical_cloud__quote__api_rw','canonical_cloud__quote.canonical_quote','DELETE')"
assert_scalar f "SELECT has_table_privilege('canonical_cloud__quote__web_ro','canonical_cloud__quote.canonical_quote','SELECT')"

owner_count="$(psql "$API_RUNTIME" -Atq -v ON_ERROR_STOP=1 <<'SQL' | grep -E '^[0-9]+$' | tail -1
BEGIN;
SET LOCAL app.current_subject = 'atomicity-owner';
SELECT count(*) FROM canonical_cloud__quote.canonical_quote;
ROLLBACK;
SQL
)"
other_count="$(psql "$API_RUNTIME" -Atq -v ON_ERROR_STOP=1 <<'SQL' | grep -E '^[0-9]+$' | tail -1
BEGIN;
SET LOCAL app.current_subject = 'other-owner';
SELECT count(*) FROM canonical_cloud__quote.canonical_quote;
ROLLBACK;
SQL
)"
test "$owner_count" = "2"
test "$other_count" = "0"

if psql "$WEB_RUNTIME" -v ON_ERROR_STOP=1 \
  -c "SELECT count(*) FROM canonical_cloud__quote.canonical_quote" \
  >"$ARTIFACTS/web-read.out" 2>"$ARTIFACTS/web-read.err"
then
  echo "web role unexpectedly read Canonical quote rows" >&2
  exit 1
fi

grep -Eqi 'permission denied|no permission' "$ARTIFACTS/web-read.err"

printf 'Canonical quote migration atomicity certification passed on PostgreSQL %s.\n' "$PG_MAJOR"
