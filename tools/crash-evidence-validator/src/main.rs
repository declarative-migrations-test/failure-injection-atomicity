use serde_json::{Map, Value};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

const SCHEMA_VERSION: &str = "declarative-migrations.crash-evidence.v1";
const FAULT_POINTS: [&str; 4] = [
    "before_transaction",
    "during_transactional_ddl",
    "after_ddl_before_bookkeeping",
    "after_bookkeeping_before_exit",
];
const REQUIRED_DIAGNOSTICS: [&str; 6] = [
    "fault_point",
    "transaction_state",
    "bookkeeping_state",
    "lock_state",
    "readiness_state",
    "recovery_result",
];
const FORBIDDEN_KEYS: [&str; 9] = [
    "databaseUrl",
    "connectionString",
    "password",
    "credential",
    "credentials",
    "token",
    "secret",
    "productionDatabase",
    "productionData",
];

type Result<T> = std::result::Result<T, String>;

fn object<'a>(value: &'a Value, context: &str) -> Result<&'a Map<String, Value>> {
    value
        .as_object()
        .ok_or_else(|| format!("{context} must be an object"))
}

fn string<'a>(value: &'a Value, context: &str) -> Result<&'a str> {
    value
        .as_str()
        .ok_or_else(|| format!("{context} must be a string"))
}

fn bool_value(value: &Value, context: &str) -> Result<bool> {
    value
        .as_bool()
        .ok_or_else(|| format!("{context} must be a boolean"))
}

fn u64_value(value: &Value, context: &str) -> Result<u64> {
    value
        .as_u64()
        .ok_or_else(|| format!("{context} must be a non-negative integer"))
}

fn required<'a>(map: &'a Map<String, Value>, key: &str, context: &str) -> Result<&'a Value> {
    map.get(key)
        .ok_or_else(|| format!("{context} missing required key: {key}"))
}

fn require_exact_keys(map: &Map<String, Value>, expected: &[&str], context: &str) -> Result<()> {
    let observed = map.keys().map(String::as_str).collect::<BTreeSet<_>>();
    let expected = expected.iter().copied().collect::<BTreeSet<_>>();
    if observed == expected {
        return Ok(());
    }
    let missing = expected.difference(&observed).copied().collect::<Vec<_>>();
    let unexpected = observed.difference(&expected).copied().collect::<Vec<_>>();
    Err(format!(
        "{context} keys drifted: missing={missing:?} unexpected={unexpected:?}"
    ))
}

fn is_lower_hex(value: &str, len: usize) -> bool {
    value.len() == len
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn is_scenario_id(value: &str) -> bool {
    (3..=64).contains(&value.len())
        && value
            .bytes()
            .enumerate()
            .all(|(i, b)| b.is_ascii_lowercase() || b.is_ascii_digit() || (i > 0 && b == b'-'))
        && value
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphanumeric)
}

fn is_fixture_identity(value: &str) -> bool {
    let Some(rest) = value.strip_prefix("fixture:") else {
        return false;
    };
    (3..=128).contains(&rest.len())
        && rest.bytes().enumerate().all(|(i, b)| {
            b.is_ascii_lowercase()
                || b.is_ascii_digit()
                || (i > 0 && matches!(b, b':' | b'-'))
        })
        && rest
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphanumeric)
}

fn is_engine_version(value: &str) -> bool {
    let parts = value.split('.').collect::<Vec<_>>();
    (1..=3).contains(&parts.len())
        && parts
            .iter()
            .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()))
}

fn walk_forbidden_keys(value: &Value, found: &mut BTreeSet<String>) {
    match value {
        Value::Object(map) => {
            for (key, child) in map {
                if FORBIDDEN_KEYS.contains(&key.as_str()) {
                    found.insert(key.clone());
                }
                walk_forbidden_keys(child, found);
            }
        }
        Value::Array(items) => {
            for child in items {
                walk_forbidden_keys(child, found);
            }
        }
        _ => {}
    }
}

fn expected_observation(
    fault_point: &str,
) -> Option<(&'static str, &'static str, u64, &'static str)> {
    match fault_point {
        "before_transaction" => Some(("unchanged", "absent", 0, "blocked_until_retry")),
        "during_transactional_ddl" | "after_ddl_before_bookkeeping" => {
            Some(("rolled_back", "absent", 0, "blocked_until_retry"))
        }
        "after_bookkeeping_before_exit" => Some(("applied", "present", 1, "ready")),
        _ => None,
    }
}

fn validate(schema: &Value, matrix: &Value) -> Result<usize> {
    let schema = object(schema, "schema")?;
    if string(required(schema, "$schema", "schema")?, "schema.$schema")?
        != "https://json-schema.org/draft/2020-12/schema"
    {
        return Err("crash evidence schema must use JSON Schema Draft 2020-12".into());
    }
    if bool_value(
        required(schema, "additionalProperties", "schema")?,
        "schema.additionalProperties",
    )? {
        return Err("crash evidence root must reject unknown fields".into());
    }
    let properties = object(required(schema, "properties", "schema")?, "schema.properties")?;
    let schema_version = object(
        required(properties, "schemaVersion", "schema.properties")?,
        "schema.properties.schemaVersion",
    )?;
    if string(
        required(schema_version, "const", "schema.properties.schemaVersion")?,
        "schema.properties.schemaVersion.const",
    )? != SCHEMA_VERSION
    {
        return Err("schema version authority drifted".into());
    }

    let matrix_obj = object(matrix, "matrix root")?;
    require_exact_keys(matrix_obj, &["schemaVersion", "cases"], "matrix root")?;
    if string(
        required(matrix_obj, "schemaVersion", "matrix root")?,
        "matrix.schemaVersion",
    )? != SCHEMA_VERSION
    {
        return Err("matrix schema version drifted".into());
    }
    let cases = required(matrix_obj, "cases", "matrix root")?
        .as_array()
        .ok_or_else(|| "matrix cases must be an array".to_string())?;

    let mut observed_fault_points = BTreeSet::new();
    let mut observed_scenario_ids = BTreeSet::new();

    for (index, case) in cases.iter().enumerate() {
        let context = format!("case[{index}]");
        let case_obj = object(case, &context)?;
        require_exact_keys(
            case_obj,
            &[
                "scenarioId",
                "faultPoint",
                "fixture",
                "source",
                "observation",
                "outcome",
                "recoveryAction",
                "diagnostics",
                "externalSideEffects",
            ],
            &context,
        )?;

        let scenario_id = string(
            required(case_obj, "scenarioId", &context)?,
            &format!("{context}.scenarioId"),
        )?;
        if !is_scenario_id(scenario_id) {
            return Err(format!("{context} scenarioId is not canonical"));
        }
        if !observed_scenario_ids.insert(scenario_id.to_owned()) {
            return Err(format!("duplicate scenarioId: {scenario_id}"));
        }

        let fault_point = string(
            required(case_obj, "faultPoint", &context)?,
            &format!("{context}.faultPoint"),
        )?;
        if !FAULT_POINTS.contains(&fault_point) {
            return Err(format!("{context} has unknown fault point: {fault_point}"));
        }
        if !observed_fault_points.insert(fault_point.to_owned()) {
            return Err(format!("duplicate fault point: {fault_point}"));
        }

        let fixture = object(
            required(case_obj, "fixture", &context)?,
            &format!("{context}.fixture"),
        )?;
        require_exact_keys(
            fixture,
            &[
                "databaseIdentity",
                "engine",
                "engineVersion",
                "ephemeral",
                "syntheticData",
            ],
            &format!("{context}.fixture"),
        )?;
        if !bool_value(
            required(fixture, "ephemeral", &context)?,
            &format!("{context}.fixture.ephemeral"),
        )? || !bool_value(
            required(fixture, "syntheticData", &context)?,
            &format!("{context}.fixture.syntheticData"),
        )? {
            return Err(format!("{context} is not an ephemeral synthetic fixture"));
        }
        let database_identity = string(
            required(fixture, "databaseIdentity", &context)?,
            &format!("{context}.fixture.databaseIdentity"),
        )?;
        if !is_fixture_identity(database_identity) {
            return Err(format!("{context} database identity is not fixture-scoped"));
        }
        let engine = string(
            required(fixture, "engine", &context)?,
            &format!("{context}.fixture.engine"),
        )?;
        if !matches!(engine, "postgresql" | "cockroachdb") {
            return Err(format!("{context} engine is not supported"));
        }
        let engine_version = string(
            required(fixture, "engineVersion", &context)?,
            &format!("{context}.fixture.engineVersion"),
        )?;
        if !is_engine_version(engine_version) {
            return Err(format!("{context} engine version is not bounded"));
        }

        let source = object(
            required(case_obj, "source", &context)?,
            &format!("{context}.source"),
        )?;
        require_exact_keys(
            source,
            &["migrationTreeSha256", "testSourceSha"],
            &format!("{context}.source"),
        )?;
        let tree_sha = string(
            required(source, "migrationTreeSha256", &context)?,
            &format!("{context}.source.migrationTreeSha256"),
        )?;
        if !is_lower_hex(tree_sha, 64) {
            return Err(format!("{context} migration tree digest is not SHA-256"));
        }
        let source_sha = string(
            required(source, "testSourceSha", &context)?,
            &format!("{context}.source.testSourceSha"),
        )?;
        if !is_lower_hex(source_sha, 40) {
            return Err(format!("{context} test source revision is not an exact commit SHA"));
        }

        let observation = object(
            required(case_obj, "observation", &context)?,
            &format!("{context}.observation"),
        )?;
        require_exact_keys(
            observation,
            &[
                "knownState",
                "schemaState",
                "bookkeepingState",
                "authoritativeAppliedRecords",
                "leaseOwnerPresent",
                "readiness",
            ],
            &format!("{context}.observation"),
        )?;
        if !bool_value(
            required(observation, "knownState", &context)?,
            &format!("{context}.observation.knownState"),
        )? {
            return Err(format!(
                "{context} may not report an unknown post-crash state as evidence"
            ));
        }
        if bool_value(
            required(observation, "leaseOwnerPresent", &context)?,
            &format!("{context}.observation.leaseOwnerPresent"),
        )? {
            return Err(format!("{context} leaked a migration lease after recovery"));
        }
        let expected = expected_observation(fault_point).expect("validated fault point");
        let observed = (
            string(
                required(observation, "schemaState", &context)?,
                &format!("{context}.observation.schemaState"),
            )?,
            string(
                required(observation, "bookkeepingState", &context)?,
                &format!("{context}.observation.bookkeepingState"),
            )?,
            u64_value(
                required(observation, "authoritativeAppliedRecords", &context)?,
                &format!("{context}.observation.authoritativeAppliedRecords"),
            )?,
            string(
                required(observation, "readiness", &context)?,
                &format!("{context}.observation.readiness"),
            )?,
        );
        if observed != expected {
            return Err(format!(
                "{context} state is inconsistent with {fault_point}: {observed:?}"
            ));
        }

        let outcome = string(
            required(case_obj, "outcome", &context)?,
            &format!("{context}.outcome"),
        )?;
        let recovery = string(
            required(case_obj, "recoveryAction", &context)?,
            &format!("{context}.recoveryAction"),
        )?;
        if fault_point == "after_bookkeeping_before_exit" {
            if outcome != "converged" || recovery != "none" {
                return Err(format!(
                    "{context} must recognize the single committed applied record"
                ));
            }
        } else if outcome != "recovered" || recovery != "retry_exact_plan" {
            return Err(format!(
                "{context} must recover only by retrying the exact reviewed plan"
            ));
        }

        let diagnostics = object(
            required(case_obj, "diagnostics", &context)?,
            &format!("{context}.diagnostics"),
        )?;
        require_exact_keys(
            diagnostics,
            &["redacted", "categories"],
            &format!("{context}.diagnostics"),
        )?;
        if !bool_value(
            required(diagnostics, "redacted", &context)?,
            &format!("{context}.diagnostics.redacted"),
        )? {
            return Err(format!("{context} diagnostics are not redacted"));
        }
        let categories = required(diagnostics, "categories", &context)?
            .as_array()
            .ok_or_else(|| format!("{context}.diagnostics.categories must be an array"))?
            .iter()
            .map(|value| {
                string(value, &format!("{context}.diagnostics.categories[]")).map(str::to_owned)
            })
            .collect::<Result<BTreeSet<_>>>()?;
        let expected_categories = REQUIRED_DIAGNOSTICS
            .iter()
            .map(|value| (*value).to_owned())
            .collect::<BTreeSet<_>>();
        if categories != expected_categories {
            return Err(format!(
                "{context} diagnostics do not explain the recovered state"
            ));
        }
        if bool_value(
            required(case_obj, "externalSideEffects", &context)?,
            &format!("{context}.externalSideEffects"),
        )? {
            return Err(format!("{context} permits external side effects"));
        }
    }

    let expected_fault_points = FAULT_POINTS
        .iter()
        .map(|value| (*value).to_owned())
        .collect::<BTreeSet<_>>();
    if observed_fault_points != expected_fault_points {
        let missing = expected_fault_points
            .difference(&observed_fault_points)
            .cloned()
            .collect::<Vec<_>>();
        return Err(format!("crash matrix coverage drifted: missing={missing:?}"));
    }

    let mut forbidden = BTreeSet::new();
    walk_forbidden_keys(matrix, &mut forbidden);
    if !forbidden.is_empty() {
        return Err(format!(
            "credential or production-bearing fields entered evidence: {forbidden:?}"
        ));
    }
    let serialized =
        serde_json::to_string(matrix).map_err(|error| format!("serialize matrix: {error}"))?;
    let lower = serialized.to_ascii_lowercase();
    if ["postgres://", "postgresql://", "cockroachdb://"]
        .iter()
        .any(|needle| lower.contains(needle))
    {
        return Err("database connection URL entered crash evidence".into());
    }

    Ok(cases.len())
}

fn read_json(path: &Path) -> Result<Value> {
    let content =
        fs::read_to_string(path).map_err(|error| format!("read {}: {error}", path.display()))?;
    serde_json::from_str(&content).map_err(|error| format!("parse {}: {error}", path.display()))
}

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("validator crate must live under tools/crash-evidence-validator")
        .to_path_buf()
}

fn main() {
    let root = repo_root();
    let schema = read_json(&root.join("evidence/crash-evidence.schema.json"));
    let matrix = read_json(&root.join("evidence/crash-matrix.json"));
    let result = schema.and_then(|schema| matrix.and_then(|matrix| validate(&schema, &matrix)));
    match result {
        Ok(count) => println!(
            "validated {count} crash boundaries against {SCHEMA_VERSION}; all evidence is fixture-scoped, redacted, bounded, and side-effect free"
        ),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn case(
        scenario_id: &str,
        fault_point: &str,
        schema_state: &str,
        bookkeeping_state: &str,
        records: u64,
        readiness: &str,
        outcome: &str,
        recovery_action: &str,
    ) -> Value {
        json!({
            "scenarioId": scenario_id,
            "faultPoint": fault_point,
            "fixture": {
                "databaseIdentity": format!("fixture:den-3430:{scenario_id}"),
                "engine": "postgresql",
                "engineVersion": "17",
                "ephemeral": true,
                "syntheticData": true
            },
            "source": {
                "migrationTreeSha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "testSourceSha": "abcdef0123456789abcdef0123456789abcdef01"
            },
            "observation": {
                "knownState": true,
                "schemaState": schema_state,
                "bookkeepingState": bookkeeping_state,
                "authoritativeAppliedRecords": records,
                "leaseOwnerPresent": false,
                "readiness": readiness
            },
            "outcome": outcome,
            "recoveryAction": recovery_action,
            "diagnostics": {
                "redacted": true,
                "categories": REQUIRED_DIAGNOSTICS
            },
            "externalSideEffects": false
        })
    }

    fn fixture() -> (Value, Value) {
        let schema = json!({
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "additionalProperties": false,
            "properties": {"schemaVersion": {"const": SCHEMA_VERSION}}
        });
        let matrix = json!({
            "schemaVersion": SCHEMA_VERSION,
            "cases": [
                case("crash-before-transaction", "before_transaction", "unchanged", "absent", 0, "blocked_until_retry", "recovered", "retry_exact_plan"),
                case("crash-during-transactional-ddl", "during_transactional_ddl", "rolled_back", "absent", 0, "blocked_until_retry", "recovered", "retry_exact_plan"),
                case("crash-after-ddl-before-bookkeeping", "after_ddl_before_bookkeeping", "rolled_back", "absent", 0, "blocked_until_retry", "recovered", "retry_exact_plan"),
                case("crash-after-bookkeeping-before-exit", "after_bookkeeping_before_exit", "applied", "present", 1, "ready", "converged", "none")
            ]
        });
        (schema, matrix)
    }

    #[test]
    fn accepts_current_golden_semantics() {
        let (schema, matrix) = fixture();
        assert_eq!(validate(&schema, &matrix).unwrap(), 4);
    }

    #[test]
    fn rejects_unknown_authority_field() {
        let (schema, mut matrix) = fixture();
        matrix
            .as_object_mut()
            .unwrap()
            .insert("extra".into(), Value::Bool(true));
        assert!(validate(&schema, &matrix).unwrap_err().contains("keys drifted"));
    }

    #[test]
    fn rejects_non_ephemeral_fixture() {
        let (schema, mut matrix) = fixture();
        matrix["cases"][0]["fixture"]["ephemeral"] = Value::Bool(false);
        assert!(validate(&schema, &matrix)
            .unwrap_err()
            .contains("ephemeral synthetic fixture"));
    }

    #[test]
    fn rejects_wrong_fault_state() {
        let (schema, mut matrix) = fixture();
        matrix["cases"][1]["observation"]["schemaState"] = Value::String("applied".into());
        assert!(validate(&schema, &matrix)
            .unwrap_err()
            .contains("state is inconsistent"));
    }

    #[test]
    fn rejects_duplicate_history_identity() {
        let (schema, mut matrix) = fixture();
        let scenario = matrix["cases"][0]["scenarioId"].clone();
        matrix["cases"][1]["scenarioId"] = scenario;
        assert!(validate(&schema, &matrix)
            .unwrap_err()
            .contains("duplicate scenarioId"));
    }

    #[test]
    fn rejects_secret_bearing_field() {
        let (schema, mut matrix) = fixture();
        matrix["cases"][0]["diagnostics"]
            .as_object_mut()
            .unwrap()
            .insert("secret".into(), Value::String("redacted".into()));
        let error = validate(&schema, &matrix).unwrap_err();
        assert!(error.contains("keys drifted") || error.contains("credential or production-bearing"));
    }

    #[test]
    fn rejects_database_url_anywhere_in_evidence() {
        let (schema, mut matrix) = fixture();
        matrix["cases"][0]["fixture"]["databaseIdentity"] =
            Value::String("postgresql://bad".into());
        let error = validate(&schema, &matrix).unwrap_err();
        assert!(error.contains("fixture-scoped") || error.contains("database connection URL"));
    }
}
