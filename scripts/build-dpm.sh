#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$root/vendor/dpm"
expected="21eb846e356b2a5aff068b21e77903e6cca50452"
rm -rf "$source_dir"
mkdir -p "$(dirname "$source_dir")"
git clone --filter=blob:none https://github.com/declarative-migrations/declarative-postgres-migrate.rs.git "$source_dir"
git -C "$source_dir" checkout --detach "$expected"
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$expected" ]]
cargo build --locked --release --manifest-path "$source_dir/Cargo.toml" --bin dpm
printf '%s\n' "$source_dir/target/release/dpm"
