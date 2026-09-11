#!/usr/bin/env python3
import json
import re
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "bootstrap-manifest.json").read_text())
dependency = json.loads((root / "production-dependency.json").read_text())
source = json.loads((root / "canonical-quote-source.json").read_text())
expected_dpm = "d05a7880987ddaa271fa88b52c787390ef12b899"

required = [
    "README.md",
    "AGENTS.md",
    "LICENSE",
    ".gitmodules",
    "bootstrap-manifest.json",
    "production-dependency.json",
    "canonical-quote-source.json",
    "scripts/build-dpm.sh",
    "scripts/fetch-exact-public-source.sh",
    "scripts/test-failure-injection.sh",
    "scripts/test-failed-step.sh",
    "scripts/test-canonical-quote-atomicity.sh",
    ".github/workflows/ci.yml",
    ".github/workflows/canonical-quote.yml",
]
missing = [path for path in required if not (root / path).exists()]
if missing:
    raise SystemExit(f"missing required files: {missing}")

production = manifest.get("production_dependency", {})
if production.get("repository") != "declarative-migrations/declarative-postgres-migrate.rs":
    raise SystemExit("production dependency repository drifted")
if production.get("path") != "vendor/declarative-postgres-migrate.rs":
    raise SystemExit("production dependency path drifted")
if production.get("transport") != "git-submodule":
    raise SystemExit("production dependency transport drifted")
if production.get("commit") != expected_dpm:
    raise SystemExit("production dependency pin drifted")
if dependency.get("repository") != production["repository"]:
    raise SystemExit("production dependency ledger repository drifted")
if dependency.get("commit") != expected_dpm:
    raise SystemExit("production dependency ledger commit drifted")
if dependency.get("transport") != "pinned git submodule":
    raise SystemExit("production dependency ledger transport drifted")

expected_source_keys = {
    "schemaVersion",
    "sourceRepository",
    "sourceCommit",
    "schemaPath",
    "schemaSha256",
    "bootstrapPath",
    "grantsPath",
    "namespacePath",
    "dpmRepository",
    "dpmCommit",
    "minimumPostgresMajor",
}
if set(source) != expected_source_keys:
    raise SystemExit("Canonical quote source manifest fields drifted")
if source["schemaVersion"] != 1:
    raise SystemExit("Canonical source manifest version drifted")
if source["sourceRepository"] != "canonical-cloud/canonical-api-server.rs":
    raise SystemExit("Canonical source repository drifted")
if not re.fullmatch(r"[0-9a-f]{40}", source["sourceCommit"]):
    raise SystemExit("Canonical source commit is not an exact SHA")
if source["schemaPath"] != "db/schema.sql":
    raise SystemExit("Canonical schema path drifted")
if not re.fullmatch(r"[0-9a-f]{64}", source["schemaSha256"]):
    raise SystemExit("Canonical schema digest is invalid")
if source["bootstrapPath"] != "db/bootstrap.sql":
    raise SystemExit("Canonical bootstrap path drifted")
if source["grantsPath"] != "db/grants.sql":
    raise SystemExit("Canonical grants path drifted")
if source["namespacePath"] != "db/namespace.json":
    raise SystemExit("Canonical namespace path drifted")
if source["dpmRepository"] != production["repository"]:
    raise SystemExit("Canonical DPM repository drifted")
if source["dpmCommit"] != expected_dpm:
    raise SystemExit("Canonical DPM revision drifted")
if source["minimumPostgresMajor"] != 17:
    raise SystemExit("Canonical minimum PostgreSQL major drifted")

index = subprocess.check_output(
    ["git", "-C", str(root), "ls-files", "--stage", "-z"],
    text=False,
)
tracked_files: list[Path] = []
observed_gitlink = None
for entry in index.split(b"\0"):
    if not entry:
        continue
    metadata, raw_path = entry.split(b"\t", 1)
    mode, object_id, stage = metadata.decode("ascii").split()
    path = Path(raw_path.decode("utf-8"))
    if stage != "0":
        raise SystemExit(f"unmerged index entry for {path}")
    if mode == "160000":
        if path.as_posix() == production["path"]:
            observed_gitlink = object_id
        continue
    tracked_files.append(root / path)
if observed_gitlink != expected_dpm:
    raise SystemExit(
        f"production dependency gitlink drifted: expected {expected_dpm}, "
        f"observed {observed_gitlink}"
    )

fetch_helper = (root / "scripts/fetch-exact-public-source.sh").read_text()
for required_text in (
    'https://github.com/${repository}.git',
    'fetch --quiet --no-tags --depth=1 origin "$commit"',
    'checkout --quiet --detach FETCH_HEAD',
    'rev-parse HEAD',
    'remote remove origin',
):
    if required_text not in fetch_helper:
        raise SystemExit(f"exact-source helper omits {required_text}")

workflow = (root / ".github/workflows/canonical-quote.yml").read_text()
for required_text in (
    "scripts/fetch-exact-public-source.sh",
    source["sourceRepository"],
    source["sourceCommit"],
    "postgres: ['17', '18']",
    "toolchain: \"1.95.0\"",
    "persist-credentials: false",
    source["schemaPath"],
    source["bootstrapPath"],
    source["grantsPath"],
    source["namespacePath"],
):
    if required_text not in workflow:
        raise SystemExit(f"Canonical workflow omits {required_text}")
if f"repository: {source['sourceRepository']}" in workflow:
    raise SystemExit("Canonical workflow must not require cross-organization checkout credentials")

base_workflow = (root / ".github/workflows/ci.yml").read_text()
if 'toolchain: "1.95.0"' not in base_workflow:
    raise SystemExit("generic failure workflow does not pin Rust 1.95.0")

credential = re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}|BEGIN [A-Z ]*PRIVATE KEY")
for path in tracked_files:
    if not path.is_file() or path.stat().st_size > 1_000_000:
        continue
    try:
        text = path.read_text()
    except UnicodeDecodeError:
        continue
    if any(marker in text for marker in ("<" * 7, "=" * 7, ">" * 7)):
        raise SystemExit(f"conflict marker in {path.relative_to(root)}")
    if credential.search(text):
        raise SystemExit(f"credential-shaped content in {path.relative_to(root)}")

print(
    f"validated {manifest['organization']}/{manifest['repository']} with "
    f"Canonical source {source['sourceCommit']} and DPM {expected_dpm}"
)
