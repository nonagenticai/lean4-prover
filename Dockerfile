# ==============================================================================
# lean4-prover — Rust service + a Lean 4 toolchain with a prebuilt Mathlib.
#
# Stage 1 (rust-build)  compile the service. Nothing Lean-related here.
# Stage 2 (lean-build)  elan + the pinned toolchain + Mathlib oleans.
# Stage 3 (production)  both of the above, non-root, no compilers.
#
# Two things in stage 2 are load-bearing and were both wrong in the Python
# image, which is why this file does not simply carry them over:
#
#   * `lake-manifest.json` is COPIED IN. Without it `lake update` resolves
#     Mathlib HEAD at build time, so an unchanged repo produces a different
#     image tomorrow — and a Mathlib that has moved to a newer toolchain fails
#     the build with nothing of ours having changed.
#
#   * `lake exe cache get` runs BEFORE `lake build`. Mathlib publishes prebuilt
#     oleans; without them the targeted build compiles a large slice of the
#     library from source, which is hours against any sensible CI budget.
#
# Sources are kept in the runtime image on purpose. Deleting the package
# `.lean` files (the Python image did) saves ~0.5 GB but makes `lake env lean`
# depend on an olean-only layout nobody has exercised; the image is not size
# constrained, so it is not a trade worth making blind.
# ==============================================================================

# Docker Hub by default, so an outside contributor builds with no setup.
# Override to build against a mirror:
#   docker build --build-arg BASE_REGISTRY=my.registry.example .
ARG BASE_REGISTRY=docker.io

# -----------------------------
# Stage 1 — the Rust service
# -----------------------------
FROM ${BASE_REGISTRY}/library/rust:1.98-bookworm AS rust-build

WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --locked \
 && mkdir -p /out \
 && cp target/release/lean4-prover /out/


# -----------------------------
# Stage 2 — Lean toolchain + Mathlib
# -----------------------------
FROM ${BASE_REGISTRY}/library/debian:12-slim AS lean-build

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
      git \
      ca-certificates \
      xz-utils \
      bzip2 \
    && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# elan into /opt/elan (not $HOME) so it can be copied into the runtime once.
ENV ELAN_HOME=/opt/elan
RUN curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
    | sh -s -- -y --default-toolchain none --no-modify-path
ENV PATH="/opt/elan/bin:$PATH"

WORKDIR /lean-project
COPY lean/lean-toolchain lean/lakefile.lean lean/lake-manifest.json ./

# `lake exe cache get` also materialises the packages the manifest names, so no
# `lake update` is needed — and running it would discard the pin.
#
# ⚠️ NO PACKAGE'S `.git` MAY BE DELETED. Lake resolves EVERY package in the
# workspace by running `git remote get-url origin` in its directory and comparing
# it with the manifest URL. With `.git` stripped that command fails, lake decides
# the URL changed, and it DELETES the checkout and re-clones from GitHub — which
# a deployment whose egress policy blocks GitHub cannot do. Measured on a
# deployed pod 2026-11-13:
# with every `.git` removed, mathlib was deleted and every prove failed with
# "failed to read file .../Std/Do/SPred/Notation.olean"; with only mathlib's
# `.git` restored, the same thing happened to `plausible` — it walks the packages
# and fails at the first one. Keeping them all costs 954 MB (measured on the
# deployed clone), of which mathlib is 427 MB.
RUN lake exe cache get \
 && lake build Mathlib.Tactic.NormNum Mathlib.Tactic.Ring Mathlib.Tactic.Linarith \
 && find .lake -name "*.c" -type f -delete


# -----------------------------
# Stage 3 — runtime
# -----------------------------
FROM ${BASE_REGISTRY}/library/debian:12-slim AS production

ENV ELAN_HOME=/opt/elan \
    PATH="/opt/elan/bin:/usr/local/bin:/usr/bin:/bin" \
    LEAN4_PROVER_PROJECT_DIR=/lean-project \
    PORT=8812

# curl is the healthcheck; git is needed by lake when it inspects the project.
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
      git \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Ownership is applied BY THE COPY, not by a recursive chown afterwards. The two
# trees are 7.0 GB and 3.6 GB; `chown -R` over them measured 615 s in the build
# that timed out at 60 minutes on 2026-11-13, which is build time spent doing
# nothing. `--chown` is applied while the layers are extracted.
COPY --from=lean-build --chown=1000:1000 /opt/elan /opt/elan
COPY --from=lean-build --chown=1000:1000 /lean-project /lean-project
COPY --from=rust-build /out/lean4-prover /usr/local/bin/lean4-prover

# The `chmod -R a+rX /opt/elan` that used to live here is gone with it: every
# file arrives 0644/0755 from the builder, which is already world-readable and
# world-executable, and the runtime USER owns them now.
#
# ⚠️ `/usr/sbin/useradd` BY ABSOLUTE PATH, not `useradd`. The ENV PATH above is
# the subprocess contract (exactly PATH + ELAN_HOME reaches the child), and it
# does NOT contain /usr/sbin — where Debian installs useradd. A bare `useradd`
# dies with "/bin/sh: 1: useradd: not found" (exit 127) even though the binary
# is present and the `passwd` package is installed. Measured twice on
# 2026-11-13; the second time after installing `passwd` to "fix" it, whose own
# apt output said "already the newest version".
RUN /usr/sbin/useradd -m -u 1000 appuser

USER 1000:1000

EXPOSE 8812
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["curl", "-f", "http://localhost:8812/health"]

ENTRYPOINT ["/usr/local/bin/lean4-prover"]
