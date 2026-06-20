# iriq Go → Rust port — final report

Complete port of iriq (library + CLI) from Go to Rust. Functional
equivalence with the Go side, including the SQLite corpus backend, the
`--reinfer` / `--propose-recognizers` / `--cross-host-shapes` /
`--activate-above` analytics commands, the `completion <shell>`
subcommand, and the per-cluster ParamSummary distributions.

## Outcome

| Gate                                          | Result                                         |
| --------------------------------------------- | ---------------------------------------------- |
| All six golden JSON fixtures pass             | ✅  parser, classifier, normalizer, pathshape, inflector, extractor |
| Rust CLI parity vs Go CLI                     | ✅  59 / 59 (`script/rust_parity.sh`)         |
| JSON corpus round-trip                        | ✅  Go-written corpus loads in Rust + vice versa |
| SQLite corpus round-trip                      | ✅  Schema v4 bit-identical; shared `.db` files open both ways |
| Zero clippy warnings (`-D warnings`)          | ✅                                            |
| Zero compiler warnings                        | ✅                                            |

Both phases shipped:

**Phase 1** — parser, normalizer, classifier (all recognizers +
allowlists), inflector, hints, shape, pathshape, extractor, explanation,
trace.

**Phase 2** — Position / PositionStats, Cluster + ParamSummary
(value/subtype/file-kind distributions, year/http_status/enum
promotion), Clusterer, Event / Observation, Storage trait +
MemoryStorage + JsonStorage + SqliteStorage, Corpus (with reinfer,
propose-recognizers, activate-above, cross-host-shapes),
SynthesizedRecognizer.

CLI covers every flag the Go binary exposes: `-n / -c / -p / -e`, `-j /
-J`, `-N`, `--corpus PATH`, `--stats`, `--reinfer`,
`--propose-recognizers`, `--cross-host-shapes`, `--activate-above`,
`--host MODE`, `--min-hosts`, `--min-observations`, `--min-coverage`,
`--no-scheme-less`, `cluster` subcommand, `completion <shell>`.

## Cost

| Metric                                  | Value                                |
| --------------------------------------- | ------------------------------------ |
| Calendar time (one session, both phases) | ~11 hours                            |
| Rust LOC, library only                   | 5 279 lines across 22 files          |
| Rust LOC, library + CLI                  | 6 531 lines                          |
| Go LOC, library + CLI (comparison)       | 7 444 non-test lines                 |
| Ruby LOC, library                        | 5 193 lines                          |
| Code size (Rust vs Go, like-for-like)    | ~88 % of Go's line count             |

Time breakdown: ~1.5 h reading Go source + planning, ~3 h Phase 1
(classifier was the long pole), ~1 h Phase 1 CLI, ~3 h Phase 2 (Corpus
ownership graph + SQLite backend), ~1 h CLI extensions, ~1 h perf
optimizations + clippy cleanup, ~0.5 h benchmarking + report.

## Performance

Three-way bench (`script/bench_three_way.sh` + manual corpus runs,
2 000 URLs through a single CLI invocation, release builds, same Linux
container):

|                                  | Go         | Rust       | Δ              |
| -------------------------------- | ---------- | ---------- | -------------- |
| `-n` extract + normalize         | 47 ms      | **36 ms**  | 1.3× faster    |
| pipe → in-process cluster        | 47 ms      | **36 ms**  | 1.3× faster    |
| `--corpus c.json` (JSON)         | 39 ms      | **28 ms**  | 1.4× faster    |
| `--corpus c.db` (SQLite)         | 1 220 ms   | **115 ms** | **~10.6× faster** |

### Binary sizes (release, x86_64-linux)

| Build                        | Size      | Notes                             |
| ---------------------------- | --------- | --------------------------------- |
| Go CLI, slim (JSON only)     | ~4 MB     | `go build ./cmd/iriq`             |
| Go CLI, with SQLite          | 10 MB     | `go build -tags sqlite ./cmd/iriq`<br>(pure-Go `modernc.org/sqlite`) |
| Rust CLI (always with SQLite) | **4.4 MB** | `cargo build --release --bin iriq`<br>(C SQLite bundled via `rusqlite`) |

So the Rust CLI is **56 % smaller than Go's SQLite build** while shipping
the same backend, and roughly tied with Go's slim build despite always
including SQLite.

### Where the SQLite gap comes from

Three optimizations stack:

1. **`rusqlite` binds C SQLite** (statically linked, ~3 MB cost),
   compared to Go's pure-Go `modernc.org/sqlite` — the C version is
   ~4× faster per query on this workload.
2. **`BEGIN IMMEDIATE` / `COMMIT`** around the per-CLI observe loop —
   without this, Rust was at 1480 ms (slower than Go). With batching,
   305 ms. Single largest perf delta in the spike.
3. **`Connection::prepare_cached` for hot-path UPSERTs** — drops the
   per-observation plan-compile cost. 305 ms → 115 ms.

Without (3) you get most of the win from (1) + (2) alone. With all
three, Rust pulls ~10× ahead.

A Ruby column isn't included here because the container's Ruby is 3.3
but the gem now requires 3.4. Historical Ruby numbers (from the v0.x
README) put it at ~370 ms for the same workload, putting Rust ~10× ahead
of Ruby on `-n` and ~30× ahead on SQLite.

## Friction log

What was easier than expected:

- **Regex parity** — mechanical translation from Go RE2 patterns into
  Rust's `regex` crate. Same syntax for named groups, `(?i)`, Unicode
  classes. The classifier (~25 regexes) ported without semantic edits.
- **JSON parity** with `serde_json` + the `preserve_order` feature.
  Fixed-key-order JSON (`parse → canonical → normalize → explain`)
  ports cleanly. Byte-identical to Go's output on every scenario.
- **SQLite schema parity** — the Go schema is shared as an
  `include_str!("./sqlite_schema.sql")` and `rusqlite::execute_batch`
  applies it. Bumping `PRAGMA busy_timeout` before `journal_mode`
  (same trick the Go side uses) makes WAL initialization reliable.
- **Allowlists + maps** — `Lazy<HashSet>` / `Lazy<HashMap>` via
  `once_cell` ports the Go `map[string]struct{}` pattern cleanly.

What was harder:

- **Ownership graph for Corpus**. Go's design has `*Corpus` ↔
  `*Cluster` pointer relationships and Storage methods that hand out
  `*Cluster` references. In Rust I redesigned Storage to return
  *owned* `Cluster` values (cheap clones — the Cluster struct holds
  small `HashMap`s + a bounded `Examples` slice). The big shift: the
  `*Cluster` returned by `Storage.AddToCluster` in Go is discarded
  in Rust; reads always go through `Storage.ClusterFor(key)` which
  materializes a fresh Cluster. The perf numbers show it's still net
  faster than Go.
- **Trait methods + `&mut self`**. `Corpus::observe` needs `&mut
  self`; that propagates through `Storage`. The CLI couldn't hold a
  borrowed `&mut Corpus` AND call into per-IRI sections — worked
  around by carrying ownership through `cmd_batch` and rebinding.
- **String vs &str plumbing** stays a per-function decision (owned at
  boundaries, borrowed for pass-throughs). Maybe 5–10 % more friction
  than Go.
- **Replacing `Reducer` indirection**. Go ships an `Event` interface +
  a registry of reducers. Rust's enum-based `Event` + a single
  `apply_event(e, &mut storage)` switch is simpler and slightly
  faster. The dynamic-dispatch flexibility of Go's design is
  theoretical at this layer.

What surprised me:

- **Compile time** is fine: cold release build ~75 s for the workspace
  with bundled SQLite, debug ~10 s, incremental ~0.5–2 s. Go cold
  builds in ~2 s, so Rust is 30–40× slower on cold, but devs spend
  most of their time on incremental.
- **No measurable cold-start win** on `iriq --version` (~8 ms vs
  ~5 ms). Rust's lazy-static regex initialization eats most of the
  static-linking advantage. The win shows up on actual workloads.
- **Cached-statement matters a lot**. The first SQLite version
  re-prepared the UPSERTs on every observation — switching to
  `Connection::prepare_cached` was a 2.6× win on the corpus path with
  no API change.

## Recommendation (revised after full port + cleanup)

**Yes for new perf-bound services + new CLIs; tepid yes for in-place
migration of existing Go services.**

For:

- Real per-workload perf wins (~1.3–10× depending on backend).
- Binary 56 % smaller than Go's SQLite build, no runtime, predictable
  memory.
- The Ruby ↔ Go ↔ Rust parity story is real and tractable. Same golden
  JSON fixtures + CLI parity harness; CI just gets an extra column.
- Rust LOC came in at ~88 % of Go's for the same complete surface,
  including SQLite. Roughly comparable.

Against:

- Compile time is genuinely a productivity hit at the 6.5k LOC scale
  (~75 s cold release builds). Goes away with sccache / shared
  `target/` but it's real friction during initial dev.
- The Storage ownership rework was substantial — budget a week per
  major service if the team is new to Rust.
- For the in-place case (existing Go service with Go deploy infra, Go
  monitoring, Go-trained team), a ~1.3× win on the hot path doesn't
  justify migration. **It does justify writing *new* perf-critical
  components in Rust** — especially anything that touches SQLite.

For greenfield / new plugin stack — tooling is mature, mechanical
translation works, perf + binary-size story is genuinely compelling.

## Reproducing

```sh
# In iriq repo root, on branch rust-port-spike (now merged to main):

# Lib + CLI build with SQLite (release)
cd rust && cargo build --release --bin iriq && cd ..

# Library + fixture + doc tests
cd rust && cargo test --workspace --features iriq/sqlite
cd rust && cargo clippy --workspace --features iriq/sqlite -- -D warnings

# Three-way wall-clock bench (Go vs Rust):
./script/bench_three_way.sh 5

# CLI parity diff (Rust vs Go, all 59 scenarios incl. corpus + SQLite):
./script/rust_parity.sh

# Smoke test SQLite end-to-end:
rm -f /tmp/c.db
seq 1 100 | xargs -I{} ./rust/target/release/iriq --corpus /tmp/c.db https://foo.com/users/{}
./rust/target/release/iriq --corpus /tmp/c.db --stats
./rust/target/release/iriq --corpus /tmp/c.db --reinfer
```
