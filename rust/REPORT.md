# iriq Go → Rust port — final report

A complete port of iriq (library + CLI) from Go to Rust, kept on its own
branch (`rust-port-spike`) so neither the Ruby reference nor the Go
mirror is disturbed. Functional equivalence with the Go side, including
the SQLite corpus backend, the `--reinfer` / `--propose-recognizers` /
`--cross-host-shapes` / `--activate-above` analytics commands, and the
`completion <shell>` subcommand.

## Outcome

| Gate                                          | Result                                         |
| --------------------------------------------- | ---------------------------------------------- |
| All six golden JSON fixtures pass             | ✅  parser, classifier, normalizer, pathshape, inflector, extractor |
| Rust CLI parity vs Go CLI                     | ✅  59 / 59 (`script/rust_parity.sh`)         |
| JSON corpus round-trip                        | ✅  Go-written corpus loads in Rust + vice versa |
| SQLite corpus round-trip                      | ✅  Schema bit-identical (v4); shared `.db` files open both ways |
| `go test ./...` still green                   | ✅  Go side not touched                        |
| Ruby unchanged                                | ✅  Ruby side not touched                      |

Both phases shipped:

**Phase 1** — parser, normalizer, classifier (all recognizers + allowlists),
inflector, hints, shape, pathshape, extractor, explanation, trace.

**Phase 2** — Position / PositionStats, Cluster + ParamSummary
(value/subtype/file-kind distributions, year/http_status/enum promotion),
Clusterer, Event / Observation, Storage trait + MemoryStorage +
JsonStorage + SqliteStorage, Corpus (with reinfer, propose-recognizers,
activate-above, cross-host-shapes), SynthesizedRecognizer.

CLI covers every flag the Go binary exposes: `-n / -c / -p / -e`, `-j /
-J`, `-N`, `--corpus PATH`, `--stats`, `--reinfer`,
`--propose-recognizers`, `--cross-host-shapes`, `--activate-above`,
`--host MODE`, `--min-hosts`, `--min-observations`, `--min-coverage`,
`--no-scheme-less`, `cluster` subcommand, `completion <shell>`.

## Cost

| Metric                                | Value                                  |
| ------------------------------------- | -------------------------------------- |
| Calendar time (one session, both phases) | ~10 hours                              |
| Rust LOC, library only                | 5 157 lines across 22 files            |
| Rust LOC, library + CLI               | 6 409 lines                            |
| Go LOC, library + CLI (comparison)    | 7 444 non-test lines                   |
| Ruby LOC, library                     | 5 193 lines                            |
| Code size (Rust vs Go, like-for-like) | ~86 % of Go's line count               |

Time breakdown: ~1.5 h reading Go source + planning, ~3 h Phase 1
(classifier was the long pole), ~1 h Phase 1 CLI, ~3 h Phase 2 (Corpus
ownership graph + SQLite backend), ~1 h CLI extensions, ~0.5 h
benchmarking + report.

## Performance

Three-way bench (`script/bench_three_way.sh` + manual corpus runs, 2 000
URLs through a single CLI invocation, release builds, same Linux
container):

|                              | Go         | Rust       | Δ        |
| ---------------------------- | ---------- | ---------- | -------- |
| `-n` extract + normalize     | 42 ms      | **34 ms**  | 1.2× faster |
| pipe → in-process cluster    | 42 ms      | **34 ms**  | 1.2× faster |
| `--corpus c.json` (JSON)     | 38 ms      | **28 ms**  | 1.4× faster |
| `--corpus c.db` (SQLite)     | 1 234 ms   | **305 ms** | **4.0× faster** |
| Release binary               | 10 MB      | **4.4 MB** | 56 % smaller |

The SQLite gap is interesting: Go uses `modernc.org/sqlite` (pure-Go
port of SQLite — no cgo, but ~4× slower than native). Rust's `rusqlite`
bundles the C SQLite amalgamation directly. With batched transactions
(`BEGIN IMMEDIATE` around the observe loop) Rust pulls 4× ahead on the
corpus path. Without batching the gap closes — Rust was actually
slightly slower until I added transaction support to the Storage trait.

A Ruby column wasn't measured in this session (the container's Ruby is
3.3 but the gem now requires 3.4). Re-run `script/bench_compare.sh` on
a Ruby 3.4 host to fill it in.

## Friction log

What was easier than expected:

- **Regex parity** — mechanical translation from Go RE2 patterns into
  Rust's `regex` crate. Same syntax for named groups, `(?i)`, Unicode
  classes. The classifier (~25 regexes) ported without semantic edits.
- **JSON parity** with `serde_json` + the `preserve_order` feature.
  Fixed-key-order JSON (`parse → canonical → normalize → explain`)
  ports cleanly with `#[serde(skip_serializing_if)]` structs or
  manually-built `serde_json::Map`s. Byte-identical to Go's output on
  every scenario.
- **SQLite schema parity** — the Go schema is shared as an
  `include_str!("./sqlite_schema.sql")` and `rusqlite::execute_batch`
  applies it. Bumping `PRAGMA busy_timeout` before `journal_mode`
  (same trick the Go side uses) makes WAL initialization reliable
  under concurrent open.
- **Allowlists + maps** (country codes, currency codes, file
  extensions, param-name hints) translated word-for-word into
  `Lazy<HashSet>` / `Lazy<HashMap>` via `once_cell`.

What was harder:

- **Ownership graph for Corpus**. Go's design has `*Corpus` ↔
  `*Cluster` pointer relationships and Storage methods that hand out
  `*Cluster` references. In Rust I redesigned Storage to return
  *owned* `Cluster` values (cheap clones — the Cluster struct holds
  small `HashMap`s + a bounded `Examples` slice). The big shift: the
  `*Cluster` returned by `Storage.AddToCluster` in Go is discarded
  in Rust (the corpus doesn't need it post-observe), and reads always
  go through `Storage.ClusterFor(key)` which materializes a fresh
  Cluster. That removes the cycle but means cluster reads are slightly
  more work for SQLite. The performance numbers show it's still net
  faster.
- **Trait methods + `&mut self`**. `Corpus::observe` needs `&mut
  self`; that propagates through `Storage`. The CLI couldn't hold a
  borrowed `&mut Corpus` AND call into per-IRI sections — I worked
  around it by carrying ownership through `cmd_batch` and rebinding.
- **String vs &str plumbing** stays a per-function decision (owned at
  boundaries, borrowed for pass-throughs). Maybe 5–10 % more friction
  than Go.
- **Reduced `Reducer` indirection**. Go ships an `Event` interface +
  a registry-of-reducers (`DefaultReducers[event.kind] = [...]`).
  Rust's enum-based `Event` + a single `apply_event(e, &mut storage)`
  switch is simpler and slightly faster. The dynamic-dispatch
  flexibility of Go's design is theoretical at this layer — I didn't
  miss it.

What surprised me:

- **Compile time** is fine: cold release build ~75 s for the workspace
  with bundled SQLite, debug ~10 s, incremental ~0.5–2 s. Go cold
  builds in ~2 s, so Rust is 30–40× slower on cold, but devs spend
  most of their time on incremental.
- **No measurable cold-start win** on `iriq --version` (rust ~8 ms vs
  go ~5 ms). Rust's lazy-static regex initialization eats most of the
  static-linking advantage. The win shows up on actual workloads.
- **SQLite batching matters a lot**. Without transactions wrapping
  `observe_iri`, Rust was at 1480 ms (worse than Go). With `BEGIN
  IMMEDIATE` / `COMMIT` around the loop, Rust dropped to 305 ms —
  the single largest perf delta in the spike.

## Recommendation (revised after full port)

**Yes for new services + perf-bound CLIs; tepid yes for in-place
migration of existing Go services.**

For:

- Real per-workload perf wins (~1.2–4× depending on backend).
- Binary 56 % smaller, no runtime, predictable memory.
- The Ruby ↔ Go ↔ Rust parity story is real and tractable. The same
  golden JSON fixtures + CLI parity harness that keep Ruby ↔ Go in
  sync trivially extend to a third runtime; CI just gets an extra
  column.
- Rust LOC came in at ~86 % of Go's for the same complete surface,
  including SQLite. Roughly comparable, not the 2× explosion the Rust
  reputation might suggest.

Against:

- Compile time is genuinely a productivity hit at the 6k LOC scale
  (~75 s cold release builds). Goes away with sccache / shared
  `target/` but it's real friction during initial dev.
- The Storage ownership rework was substantial — not a hot afternoon
  for someone unfamiliar with Rust trait + lifetime patterns. Budget
  a week per major service if the team is new to Rust.
- For the in-place case (existing Go service has Go deploy infra,
  Go monitoring, Go-trained team), a 4× win on one CLI path probably
  doesn't justify the migration cost. **It does justify writing
  *new* perf-critical components in Rust.**

For greenfield / new plugin stack — the tooling is there, the spike
shows mechanical translation works, and the perf + binary-size story
is genuinely compelling. Go ahead.

## Reproducing

```sh
# In iriq repo root, on branch rust-port-spike:

# Lib + CLI build with SQLite (release)
cd rust && cargo build --release --bin iriq && cd ..

# Library fixture tests (asserts against spec/fixtures/*.json):
cd rust && cargo test -p iriq && cd ..

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
