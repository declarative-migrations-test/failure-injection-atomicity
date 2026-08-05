#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v docker >/dev/null || { echo "blocked: docker unavailable"; exit 78; }
cd "$root"; docker compose -f docker-compose.chaos.yml up -d; trap 'docker compose -f docker-compose.chaos.yml down -v' EXIT
: "${CHAOS_TEST_COMMAND:?set fault-injection command}"
bash -lc "$CHAOS_TEST_COMMAND"
