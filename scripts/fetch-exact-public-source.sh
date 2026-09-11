#!/usr/bin/env bash
set -euo pipefail
repository="${1:?repository is required}"
commit="${2:?exact commit SHA is required}"
destination="${3:?destination is required}"
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "invalid repository" >&2; exit 64; }
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid commit SHA" >&2; exit 64; }
rm -rf "$destination"
git init --quiet "$destination"
git -C "$destination" remote add origin "https://github.com/${repository}.git"
git -C "$destination" -c protocol.version=2 fetch --quiet --no-tags --depth=1 origin "$commit"
git -C "$destination" checkout --quiet --detach FETCH_HEAD
test "$(git -C "$destination" rev-parse HEAD)" = "$commit"
git -C "$destination" remote remove origin
printf 'fetched %s at %s\n' "$repository" "$commit"
