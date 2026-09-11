#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$root/vendor/declarative-postgres-migrate.rs"
expected="d05a7880987ddaa271fa88b52c787390ef12b899"
actual="$(git -C "$source_dir" rev-parse HEAD)"
if [[ "$actual" != "$expected" ]]; then
  echo "production dependency drift: expected $expected, observed $actual" >&2
  exit 1
fi
cargo build --locked --release --manifest-path "$source_dir/Cargo.toml" --bin dpm
printf '%s\n' "$source_dir/target/release/dpm"
