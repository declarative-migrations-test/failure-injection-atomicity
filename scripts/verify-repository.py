#!/usr/bin/env python3
import json
import re
from pathlib import Path
root = Path(__file__).resolve().parents[1]
assert json.loads((root / "production-dependency.json").read_text())["commit"] == "21eb846e356b2a5aff068b21e77903e6cca50452"
for required in ["fixtures/v1.sql", "fixtures/v2.sql", "scripts/build-dpm.sh", "scripts/test-failed-step.sh", ".github/workflows/ci.yml"]:
    assert (root / required).is_file(), required
for path in root.rglob("*"):
    if path.is_file() and ".git" not in path.parts and path.stat().st_size < 1_000_000:
        text = path.read_text(errors="ignore")
        assert not any(marker in text for marker in ("<" * 7, "=" * 7, ">" * 7)), path
        assert not re.search(r"gh[pousr]_[A-Za-z0-9]{20,}", text), path
print("repository contract validated")
