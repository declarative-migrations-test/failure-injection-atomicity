#!/usr/bin/env python3
"""Validate the credential-free crash evidence contract for DEN-3430."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = ROOT / "evidence" / "crash-evidence.schema.json"
MATRIX_PATH = ROOT / "evidence" / "crash-matrix.json"
SCHEMA_VERSION = "declarative-migrations.crash-evidence.v1"
FAULT_POINTS = {
    "before_transaction",
    "during_transactional_ddl",
    "after_ddl_before_bookkeeping",
    "after_bookkeeping_before_exit",
}
REQUIRED_DIAGNOSTICS = {
    "fault_point",
    "transaction_state",
    "bookkeeping_state",
    "lock_state",
    "readiness_state",
    "recovery_result",
}
EXPECTED_OBSERVATIONS = {
    "before_transaction": ("unchanged", "absent", 0, "blocked_until_retry"),
    "during_transactional_ddl": ("rolled_back", "absent", 0, "blocked_until_retry"),
    "after_ddl_before_bookkeeping": ("rolled_back", "absent", 0, "blocked_until_retry"),
    "after_bookkeeping_before_exit": ("applied", "present", 1, "ready"),
}
FORBIDDEN_KEYS = {
    "databaseUrl",
    "connectionString",
    "password",
    "credential",
    "credentials",
    "token",
    "secret",
    "productionDatabase",
    "productionData",
}


def fail(message: str) -> None:
    raise SystemExit(message)


def walk_keys(value: Any) -> set[str]:
    if isinstance(value, dict):
        keys = set(value)
        for child in value.values():
            keys.update(walk_keys(child))
        return keys
    if isinstance(value, list):
        keys: set[str] = set()
        for child in value:
            keys.update(walk_keys(child))
        return keys
    return set()


def require_exact_keys(value: dict[str, Any], expected: set[str], context: str) -> None:
    observed = set(value)
    if observed != expected:
        fail(
            f"{context} keys drifted: missing={sorted(expected - observed)} "
            f"unexpected={sorted(observed - expected)}"
        )


def main() -> None:
    schema = json.loads(SCHEMA_PATH.read_text())
    matrix = json.loads(MATRIX_PATH.read_text())

    if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        fail("crash evidence schema must use JSON Schema Draft 2020-12")
    if schema.get("additionalProperties") is not False:
        fail("crash evidence root must reject unknown fields")
    schema_version = (
        schema.get("properties", {}).get("schemaVersion", {}).get("const")
    )
    if schema_version != SCHEMA_VERSION:
        fail("schema version authority drifted")

    require_exact_keys(matrix, {"schemaVersion", "cases"}, "matrix root")
    if matrix["schemaVersion"] != SCHEMA_VERSION:
        fail("matrix schema version drifted")
    if not isinstance(matrix["cases"], list):
        fail("matrix cases must be an array")

    observed_fault_points: set[str] = set()
    observed_scenario_ids: set[str] = set()
    for index, case in enumerate(matrix["cases"]):
        context = f"case[{index}]"
        if not isinstance(case, dict):
            fail(f"{context} must be an object")
        require_exact_keys(
            case,
            {
                "scenarioId",
                "faultPoint",
                "fixture",
                "source",
                "observation",
                "outcome",
                "recoveryAction",
                "diagnostics",
                "externalSideEffects",
            },
            context,
        )

        scenario_id = case["scenarioId"]
        if not isinstance(scenario_id, str) or not re.fullmatch(
            r"[a-z0-9][a-z0-9-]{2,63}", scenario_id
        ):
            fail(f"{context} scenarioId is not canonical")
        if scenario_id in observed_scenario_ids:
            fail(f"duplicate scenarioId: {scenario_id}")
        observed_scenario_ids.add(scenario_id)

        fault_point = case["faultPoint"]
        if fault_point not in FAULT_POINTS:
            fail(f"{context} has unknown fault point: {fault_point}")
        if fault_point in observed_fault_points:
            fail(f"duplicate fault point: {fault_point}")
        observed_fault_points.add(fault_point)

        fixture = case["fixture"]
        require_exact_keys(
            fixture,
            {
                "databaseIdentity",
                "engine",
                "engineVersion",
                "ephemeral",
                "syntheticData",
            },
            f"{context}.fixture",
        )
        if fixture["ephemeral"] is not True or fixture["syntheticData"] is not True:
            fail(f"{context} is not an ephemeral synthetic fixture")
        if not re.fullmatch(r"fixture:[a-z0-9][a-z0-9:-]{2,127}", fixture["databaseIdentity"]):
            fail(f"{context} database identity is not fixture-scoped")
        if fixture["engine"] not in {"postgresql", "cockroachdb"}:
            fail(f"{context} engine is not supported")
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", fixture["engineVersion"]):
            fail(f"{context} engine version is not bounded")

        source = case["source"]
        require_exact_keys(
            source,
            {"migrationTreeSha256", "testSourceSha"},
            f"{context}.source",
        )
        if not re.fullmatch(r"[0-9a-f]{64}", source["migrationTreeSha256"]):
            fail(f"{context} migration tree digest is not SHA-256")
        if not re.fullmatch(r"[0-9a-f]{40}", source["testSourceSha"]):
            fail(f"{context} test source revision is not an exact commit SHA")

        observation = case["observation"]
        require_exact_keys(
            observation,
            {
                "knownState",
                "schemaState",
                "bookkeepingState",
                "authoritativeAppliedRecords",
                "leaseOwnerPresent",
                "readiness",
            },
            f"{context}.observation",
        )
        if observation["knownState"] is not True:
            fail(f"{context} may not report an unknown post-crash state as evidence")
        if observation["leaseOwnerPresent"] is not False:
            fail(f"{context} leaked a migration lease after recovery")
        expected = EXPECTED_OBSERVATIONS[fault_point]
        observed = (
            observation["schemaState"],
            observation["bookkeepingState"],
            observation["authoritativeAppliedRecords"],
            observation["readiness"],
        )
        if observed != expected:
            fail(f"{context} state is inconsistent with {fault_point}: {observed!r}")

        if fault_point == "after_bookkeeping_before_exit":
            if case["outcome"] != "converged" or case["recoveryAction"] != "none":
                fail(f"{context} must recognize the single committed applied record")
        elif case["outcome"] != "recovered" or case["recoveryAction"] != "retry_exact_plan":
            fail(f"{context} must recover only by retrying the exact reviewed plan")

        diagnostics = case["diagnostics"]
        require_exact_keys(
            diagnostics,
            {"redacted", "categories"},
            f"{context}.diagnostics",
        )
        if diagnostics["redacted"] is not True:
            fail(f"{context} diagnostics are not redacted")
        if set(diagnostics["categories"]) != REQUIRED_DIAGNOSTICS:
            fail(f"{context} diagnostics do not explain the recovered state")
        if case["externalSideEffects"] is not False:
            fail(f"{context} permits external side effects")

    if observed_fault_points != FAULT_POINTS:
        fail(
            "crash matrix coverage drifted: "
            f"missing={sorted(FAULT_POINTS - observed_fault_points)}"
        )

    forbidden = walk_keys(matrix) & FORBIDDEN_KEYS
    if forbidden:
        fail(f"credential or production-bearing fields entered evidence: {sorted(forbidden)}")
    serialized = json.dumps(matrix, sort_keys=True)
    if re.search(r"(?:postgres|postgresql|cockroachdb)://", serialized, re.IGNORECASE):
        fail("database connection URL entered crash evidence")

    print(
        f"validated {len(matrix['cases'])} crash boundaries against {SCHEMA_VERSION}; "
        "all evidence is fixture-scoped, redacted, bounded, and side-effect free"
    )


if __name__ == "__main__":
    main()
