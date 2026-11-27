#!/usr/bin/env bash
# Publish the lean base image (stage `lean-base` of ./Dockerfile) to ghcr.io.
#
# ⚠️ THIS IS THE ONE DELIBERATELY RARE, SCRIPTED PUBLISH IN THIS REPOSITORY.
# The base carries elan + the pinned Lean toolchain + Mathlib and needs ~25 GB of disk to
# build, so it is not a per-merge step and cannot run on the 14 GB GitHub-hosted runner.
# The per-merge image is Dockerfile.runtime FROM the digest this script prints; CI refuses
# to build when the base tag no longer matches lean/lean-toolchain + lean/lake-manifest.json.
#
# Republish when:
#   * lean/lean-toolchain or lean/lake-manifest.json changes (CI fails until you do), OR
#   * the `lean-build` / `lean-base` stages of ./Dockerfile change (CI cannot see this —
#     tag = pins only — so this is on you; the base label records the source commit).
#
# Where: any host with Docker and >= 40 GB free (worker3 is the documented one).
# Auth:  GHCR_TOKEN (a token with write:packages) or an existing `docker login ghcr.io`.
#        The token is read from the environment and piped to docker login; never stored.
#
# Usage:
#   GHCR_TOKEN=… ./scripts/publish-lean-base.sh            # build, push, print the pin
#   ./scripts/publish-lean-base.sh --print                # print the pins/tag, do nothing
#   GHCR_USER=… (defaults to the current `gh api user` login is NOT assumed — pass it)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

IMAGE="ghcr.io/nonagenticai/lean4-prover"
MIN_FREE_GB=40

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# The base tag is a pure function of the two Lean pins: same pins => same tag.
PINS8="$(cat lean/lean-toolchain lean/lake-manifest.json | sha256_hex | cut -c1-12)"
TAG="$IMAGE:base-lean-$PINS8"

if [ "${1:-}" = "--print" ]; then
  echo "pins8:   $PINS8"
  echo "base tag: $TAG"
  exit 0
fi

# ── disk guard ───────────────────────────────────────────────────────────────
FREE_GB="$(df -Pk "$REPO_ROOT" | awk 'NR==2 {printf "%d", $4/1048576}')"
if [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then
  echo "refusing: ${FREE_GB} GB free under $REPO_ROOT, need ${MIN_FREE_GB} GB" >&2
  exit 1
fi

# ── auth ─────────────────────────────────────────────────────────────────────
if [ -n "${GHCR_TOKEN:-}" ]; then
  printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "${GHCR_USER:?set GHCR_USER with GHCR_TOKEN}" --password-stdin
else
  echo "GHCR_TOKEN not set — assuming this host is already logged in to ghcr.io" >&2
fi

# ── build ────────────────────────────────────────────────────────────────────
REVISION="$(git rev-parse HEAD)"
echo "building $TAG from $REVISION (${FREE_GB} GB free)"
docker build \
  --target lean-base \
  --label "dev.nonagentic.lean.pins=$PINS8" \
  --label "org.opencontainers.image.revision=$REVISION" \
  --label "org.opencontainers.image.source=https://github.com/nonagenticai/lean4-prover" \
  --tag "$TAG" \
  .

# ── push ─────────────────────────────────────────────────────────────────────
docker push "$TAG"

PINNED="$(docker image inspect --format '{{index .RepoDigests 0}}' "$TAG")"
case "$PINNED" in
  *"@sha256:"*) : ;;
  *) echo "could not read the pushed digest from $TAG (got '$PINNED')" >&2; exit 1 ;;
esac

cat <<EOF

Pushed. Put this line's ARG into Dockerfile.runtime and commit it:

ARG LEAN_BASE_IMAGE=$PINNED

Then make the package public if it is not already (anonymous pull must work):

  gh api -X PATCH orgs/nonagenticai/packages/container/lean4-prover -f visibility=public

and verify, with no credentials:

  DOCKER_CONFIG=\$(mktemp -d) docker manifest inspect $PINNED
EOF
