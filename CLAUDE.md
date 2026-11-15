# lean4-prover — repository instructions for coding agents

## What this service is

Lean 4 formal verification as a REST API. It is a thin I/O shell: every request
writes a `.lean` file into a prebuilt lake project and runs `lake env lean` on it.
There is no model, no GPU and no platform-specific code path. It is Rust (since
2026-11-13); the old FastAPI implementation is gone and nothing Python-related
belongs back in this tree.

## Layout

| Path | What it is |
|---|---|
| `src/main.rs` | process entry point: read env, build the app, serve, graceful shutdown |
| `src/lib.rs` | `build_app` — routes + licence gate + request counting + CORS |
| `src/config.rs` | env-driven config; the variable names are the deployed contract |
| `src/runner.rs` | subprocess supervision, diagnostic parsing, the tactic loop |
| `src/admission.rs` | the shared compute lane (semaphore + capped waiters + 503) |
| `src/auth.rs` | licence introspection, its three caches, the 401/503 answers |
| `src/routes.rs` | health, `/metrics`, `/openapi.json`, the three compute routes |
| `src/metrics.rs` | hand-rolled Prometheus exposition |
| `tests/http_contract.rs` | end-to-end HTTP contract over a fake `lake`/`lean` |
| `lean/` | the lake project: `lean-toolchain`, `lakefile.lean`, `lake-manifest.json` |
| `Dockerfile` | Rust build + elan/Mathlib stage + slim runtime |

## Things that are load-bearing — do not "simplify" them

- **The child gets its own process group** (`setpgid` in `pre_exec`) and a timeout
  kills the whole group. `lake env lean` is a wrapper; killing only the `lake` pid
  leaves `lean` resident.
- **`killpg` is only called on a real pid > 1.** `killpg(1)` is
  `kill(-1, SIGKILL)` — a broadcast that kills every process in the container.
  `runner::tests::never_kills_pid_1_or_pid_0` guards this.
- **The subprocess environment is replaced, not extended** — exactly `PATH` and
  `ELAN_HOME`. `LEAN4_PROVER_LEAN_BINARY` / `_LAKE_BINARY` therefore default to
  absolute paths under `/opt/elan/bin`, not bare `lean`/`lake`.
- **No `RLIMIT_AS`.** Lean reserves far more virtual address space than it touches,
  so a virtual-memory cap makes `lake env lean` fail to mmap its own oleans and
  report it as an unreadable file. Bound memory with the container limit instead;
  `LEAN4_PROVER_MAX_MEMORY_MB` is accepted and not enforced.
- **`lake-manifest.json` is copied into the image.** Without it, `lake update`
  resolves Mathlib HEAD at build time and an unchanged repo produces a different
  image tomorrow.
- **`lake exe cache get` runs before `lake build`.** Mathlib publishes prebuilt
  oleans; without them the build compiles a large slice of the library from source.
- **No package's `.git` may be deleted from the built project.** Lake resolves every
  package by running `git remote get-url origin` in its directory; with `.git`
  stripped it decides the URL changed, deletes the checkout and re-clones.
- **Fail closed on licences.** No token → 401. Licences unreachable and no
  last-known-good → 503, never an allow. A bare `X-Tenant-Id` is never identity.
- **Boot refuses** when `ENABLE_AUTH=true` and `LICENSE_INTROSPECT_URL` is empty.
- **CORS**: `allow_headers(Any)` and `allow_methods(Any)` may not be combined with
  `allow_credentials(true)` — tower-http panics at construction, so it is a boot
  failure. Methods and headers are enumerated instead.

## Working on the code

- `cargo fmt --all -- --check`, `cargo clippy --all-targets --locked -- -D warnings`,
  `cargo test --locked`. `scripts/pre-push.sh` runs all three.
- **Config changes go through `src/config.rs`**, and every new hardcoded path must
  carry a container-compatible default.
- CI is `.github/workflows/ci-public.yml`, on GitHub-hosted `ubuntu-latest`:
  secret scan, private-reference scan, the Rust checks and a container build.
- `.github/workflows/` must never reference a private repository, a self-hosted
  runner or an internal registry — the repo is public.
