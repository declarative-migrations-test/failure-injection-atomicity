#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$root/vendor/declarative-postgres-migrate.rs"
expected="7396f79826dc6b720771a3c6ad1905b991c7cd59"
actual="$(git -C "$source_dir" rev-parse HEAD)"
if [[ "$actual" != "$expected" ]]; then
  echo "production dependency drift: expected $expected, observed $actual" >&2
  exit 1
fi
cargo build --locked --release --manifest-path "$source_dir/Cargo.toml" --bin dpm
printf '%s\n' "$source_dir/target/release/dpm"
