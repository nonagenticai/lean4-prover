#!/usr/bin/env bash
# Pre-push gate: the same checks CI runs, locally, before the branch leaves this
# machine — so a push is not the first place a formatting or lint error surfaces.
#
# CARGO_TARGET_DIR is pinned to ONE directory per repository, resolved through the
# common git dir so that every `git worktree` of this repository shares it. N
# checkouts each growing their own multi-GB `target/` is how a disk fills up.
set -euo pipefail

common_dir="$(git rev-parse --git-common-dir)"
repo_root="$(cd "${common_dir}/.." && pwd)"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${repo_root}/target/claude}"

echo "==> cargo fmt --check"
cargo fmt --all --check

echo "==> cargo clippy -D warnings"
# The same flags CI uses, so a local pass and a green run are the same gate.
cargo clippy --all-targets --locked -- -D warnings

echo "==> cargo test"
cargo test --locked
