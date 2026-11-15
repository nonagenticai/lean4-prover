# lean4-prover

Lean 4 formal verification as a REST API. It typechecks Lean 4 source, elaborates a
term to its type, and tries a list of tactics against a goal — each request shelling
out to `lake env lean` against a lake project with Mathlib available. There is no
model, no GPU and no platform-specific code: the service is a thin, supervised
wrapper around the Lean toolchain, written in Rust.

Because the toolchain is the expensive part, the service ships as a container that
already contains elan, the pinned Lean toolchain and Mathlib's prebuilt oleans. A
request then costs one `lake env lean` invocation, not a build.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | 200 when the Lean binary is reachable, 503 when not |
| GET | `/health/live` | Liveness; touches no dependency |
| GET | `/health/ready` | Readiness; checks the Lean binary |
| GET | `/metrics` | Prometheus exposition |
| GET | `/openapi.json`, `/docs` | Schema and a docs page, when enabled (see `ENABLE_DOCS`) |
| POST | `/api/check` | Typecheck Lean source |
| POST | `/api/elaborate` | Elaborate a term and return its type |
| POST | `/api/prove` | Try tactics in order until one closes the goal |

### `POST /api/check`

```json
{"source": "example : 2 + 2 = 4 := by norm_num", "timeout": 30}
```

```json
{"valid": true, "diagnostics": [], "stdout": "", "stderr": "", "computation_time_ms": 412.5}
```

`diagnostics` entries are `{"severity": "error" | "warning" | "information", "line": 1, "column": 0, "message": "..."}`.

### `POST /api/elaborate`

```json
{"term": "fun (n : Nat) => n + 1", "context": "open Nat", "timeout": 30}
```

Adds `elaborated_type` and `valid` to the same envelope.

### `POST /api/prove`

```json
{"theorem": "example : 2 + 2 = 4", "tactics": ["norm_num"], "imports": ["Mathlib.Tactic"], "timeout": 60}
```

Adds `proven` and `successful_tactic` (null when no tactic closed the goal).

### Bounds and answers

| Condition | Answer |
|---|---|
| A limit exceeded (see below) | 422 with the field named |
| Missing or invalid licence token | 401 |
| The licence service cannot be reached | 503 — never an allow |
| The shared prove lane is saturated | 503 with `Retry-After` |
| `timeout` above 120 s | 422 (the runner also clamps the configured default) |

Limits: `source` 100,000 characters, `term` and `theorem` 50,000, `context` 100,000,
at most 50 `tactics` and 50 `imports`, `timeout` in 1..120 seconds.

## Running it

The image is the only supported way to run the service, because it needs the
toolchain and Mathlib:

```bash
docker build -t lean4-prover .
docker run --rm -p 8812:8812 -e ENABLE_AUTH=false lean4-prover
curl -s http://localhost:8812/health/live
curl -s -X POST http://localhost:8812/api/prove \
  -H 'Content-Type: application/json' \
  -d '{"theorem":"example : 2 + 2 = 4","imports":["Mathlib.Tactic"]}'
# -> {"proven":true,"successful_tactic":"norm_num",...}
```

The build reaches GitHub (elan) and the Mathlib cache, and the resulting image is
about 10.6 GB; budget roughly 25 GB of disk for the build. `BASE_REGISTRY` defaults
to `docker.io`, so no registry setup is required.

To run against a lake project you already have, build the binary with `cargo build
--release --locked` and point `LEAN4_PROVER_LEAN_BINARY`, `LEAN4_PROVER_LAKE_BINARY`,
`LEAN4_PROVER_ELAN_HOME` and `LEAN4_PROVER_PROJECT_DIR` at it.

## Configuration

Environment variables only. `.env.example` documents every knob.

| Variable | Default | Notes |
|---|---|---|
| `ENVIRONMENT` | `production` | `development` turns the docs page on |
| `ENABLE_DOCS` | `false` | Serve `/openapi.json` and `/docs` |
| `ENABLE_AUTH` | `true` | The licence gate — see [Licensing](#licensing) |
| `LICENSE_INTROSPECT_URL` | — | `POST {"token": ...}`; a 200 with `active` decides |
| `LICENSE_INTROSPECT_TIMEOUT` | `10` | Seconds, 1..120 |
| `CORS_ALLOW_ORIGINS` | — | Comma-separated origins; empty sends no CORS headers |
| `LEAN4_PROVER_BIND_HOST` / `_BIND_PORT` | `0.0.0.0` / `8812` | |
| `LEAN4_PROVER_VERSION` | `0.1.0` | Reported at startup and in metrics |
| `LEAN4_PROVER_SERVICE_NAME` | `lean4-prover` | |
| `LEAN4_PROVER_PROJECT_DIR` | `/lean-project` | The lake project |
| `LEAN4_PROVER_LEAN_BINARY` / `_LAKE_BINARY` | `/opt/elan/bin/lean`, `/opt/elan/bin/lake` | Absolute on purpose: the child's environment is replaced |
| `LEAN4_PROVER_ELAN_HOME` | `/opt/elan` | Passed to the child |
| `LEAN4_PROVER_SUBPROCESS_PATH` | `/usr/local/bin:/usr/bin:/bin:/opt/elan/bin` | The child's whole `PATH` |
| `LEAN4_PROVER_TIMEOUT` | `120` | Seconds, 1..600; each request is clamped to 120 |
| `LEAN4_PROVER_MAX_MEMORY_MB` | `4096` | Accepted for compatibility and **not enforced**; bound memory with the container limit instead |
| `GPU_LANE_PROVE_MAX_ACTIVE` / `_MAX_WAITING` / `_MAX_WAIT_S` | `2` / `8` / `30` | One admission lane, shared by check, elaborate and prove |

A malformed value refuses to boot rather than falling back silently.

## Licensing

The licence gate is **optional, and on by default**. The switch is the `ENABLE_AUTH`
environment variable; it parses as a boolean and defaults to `true`, so leaving it
unset means the gate is **enabled**. With the gate on, the service refuses to start
unless `LICENSE_INTROSPECT_URL` is set, and every compute call (`/api/check`,
`/api/elaborate`, `/api/prove`) must carry a token — in `X-Tenant-Id: Bearer <token>`
or `Authorization: Bearer <token>` — which is introspected with one
`POST {"token": ...}` to that URL. A bare `X-Tenant-Id` is never identity. The gate
fails closed: unreachable licence service means 503, not an allow.

To run this software without any licence server, set **`ENABLE_AUTH=false`**. That is
what the examples above do, and it is the only configuration in which the service
runs standalone: nothing is sent anywhere, and every request is served. Health,
metrics and the docs page are never gated.

## Development

```bash
cargo fmt --all -- --check
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked
```

Rust 1.98 or newer (edition 2024). The unit and contract tests need **no Lean
toolchain**: `tests/http_contract.rs` drives the real router and the real subprocess
runner against a stand-in `lake`/`lean`, so the timeout and process-group-kill paths
are exercised without Mathlib.

Layout: `src/main.rs` is the entry point, `src/lib.rs` assembles the app,
`src/runner.rs` supervises the child process and parses diagnostics, `src/admission.rs`
is the shared prove lane, `src/auth.rs` the licence client, `src/routes.rs` the HTTP
surface, `src/metrics.rs` the Prometheus text. `lean/` is the lake project:
`lean-toolchain` pins the toolchain, `lakefile.lean` the package, and
`lake-manifest.json` pins Mathlib (copied into the image on purpose — `lake update`
at build time would resolve Mathlib HEAD and make an unchanged repo produce a
different image tomorrow).

## Image

Three stages: the Rust binary, a Lean stage that installs elan and pulls Mathlib's
prebuilt oleans for the pinned revision, and a slim runtime carrying both. Runtime
files are owned by uid 1000 and the service runs as that user.

## Security

Do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).

## License

Apache License 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). The lake
package in `lean/` declares the same licence.
