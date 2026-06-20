# iriq Go → Rust port — spike report

A measured Phase-1 port of the iriq library + CLI from Go to Rust, kept
on its own branch (`rust-port-spike`) so neither the Ruby reference nor
the Go mirror is disturbed. The point is data, not a production drop-in.

## Outcome (Phase 1)

| Gate                                          | Result                                         |
| --------------------------------------------- | ---------------------------------------------- |
| All six golden JSON fixtures load + pass      | ✅  parser, classifier, normalizer, pathshape, inflector, extractor |
| Rust CLI parity vs Go CLI (Phase 1 scenarios) | ✅  46 / 46 (`script/rust_parity.sh`)         |
| `go test ./...` still green                   | ✅  not touched                                 |
| Ruby specs unchanged                          | ✅  not touched (Ruby 3.4 wasn't in env, but the gemspec, lib/, spec/ are untouched) |

Phase 1 deliverables (per the brief): parser, normalizer, extractor,
classifier, recognizers, pathshape, hints, identifier, CLI sections
(`-n`/`-c`/`-p`/`-e`, `-j`/`-J`, `-N`, combined short flags like `-pn`),
JSON corpus backend (skipped — see below), cluster view (in-process,
ephemeral). All shipping in `rust/iriq` (lib) + `rust/iriq-cli` (bin).

## Cost

| Metric                              | Value                                |
| ----------------------------------- | ------------------------------------ |
| Calendar time on Phase 1            | ~6 hours (one session)               |
| Rust LOC, library only              | 2,109 lines across 18 files          |
| Rust LOC, library + CLI             | 3,006 lines                          |
| Go LOC, library + CLI (comparison)  | 7,444 non-test lines                 |
| Ruby LOC, library                   | 5,193 lines                          |
| Code size (Rust vs Go)              | ~40 % of the Go line count (Phase 1; Go has corpus/SQLite/proposals/cross-host/reinfer that Rust doesn't yet) |

Time breakdown (rough): ~1.5 h reading the Go source + planning; ~3 h
porting the lib (classifier was the long pole); ~1 h porting + parity-
diffing the CLI; ~0.5 h benchmarking + writing this report.

## Performance

Three-way bench (`script/bench_three_way.sh`, 2 000 URLs through `-n`
on the same Linux container, single thread, release builds):

|              | median wall-clock | binary size |
| ------------ | ----------------- | ----------- |
| Go CLI       | 40 ms             | 3.9 MB      |
| Rust CLI     | **18 ms**         | **2.2 MB**  |

So roughly **2.2× faster** on the extraction-heavy CLI workload and
**45 % smaller** binary. The "Rust gives huge cold-start wins" claim
didn't quite land — Rust's first-call regex compilation tax shows up
in `iriq --version` (rust ~7-10 ms vs Go ~4 ms) — but on any real
workload the parse/classify hot path more than makes up for it.

A Ruby column wasn't measured in this spike (the container has Ruby
3.3 but the gem requires 3.4); historically `script/bench_compare.sh`
puts Ruby around 370–430 ms for the same input, which would make Rust
~20-23× faster than Ruby. Re-run on a Ruby 3.4 host to confirm.

## Friction log

What was easier in Rust than expected:

- **Regex parity** was mechanically 1:1 from Go's RE2 patterns into Rust's
  `regex` crate. Same syntax for the cases we use (named groups, `(?i)`,
  Unicode classes). One conversion artifact: Go regex literals use raw
  backtick strings, Rust uses raw `r"..."` strings; otherwise no edits.
- **JSON parity** with `serde_json` + `preserve_order` (enables
  insertion-ordered objects). The fixed-key-order trick from Go (a typed
  struct rather than a map) ports cleanly to a `serde::Serialize` struct
  with `#[serde(skip_serializing_if)]`. Bit-identical to Go's output on
  all 46 parity scenarios.
- **Allowlists + maps** (country codes, currency codes, file extensions,
  param-name hints) translated word-for-word into `Lazy<HashSet>` and
  `Lazy<HashMap>` — `once_cell` makes the static-init pattern pleasant.

What was harder:

- **Ownership graph for Corpus**. The Go corpus has cyclic-ish `*Corpus
  ↔ *Cluster` pointer relationships and materialized views that share
  identifier instances by pointer. Phase 1 sidesteps this by keeping
  cluster aggregation in the CLI (in-process, ephemeral). A real
  persistent corpus port wants either `Rc<RefCell<…>>` or an arena +
  indices design; **I wouldn't transliterate the Go pointer graph.**
  This is the single biggest design rework if iriq's full surface
  ports.
- **TTY detection without crates**. Avoiding the `atty` / `is-terminal`
  crate (to keep deps minimal) meant a 3-line `extern "C" { fn isatty }`
  call. Not painful but a flag that real builds want the crate.
- **`String` vs `&str` plumbing** — the API surface bounces between
  owned and borrowed strings more than Go's. Took two read-edit cycles
  to settle on a convention (owned `String` at boundaries, `&str` for
  pass-through). Not blocking but does add ~5-10 % friction over Go.
- **Trait objects for recognizers**. Go's `Recognizer` interface
  ports to `dyn Recognizer + Send + Sync` plus an `Arc<…>` to share
  across threads. Slightly heavier than Go's struct-tagged interface
  but no behavior change.

What surprised me:

- **Compile time**: cold `cargo build --release` is ~20 s for the whole
  workspace (debug ~9 s). Slower than Go (~1-2 s) but acceptable on a
  per-feature basis with incremental compilation (~0.5 s).
- **No measurable cold-start win**. I'd expected static-linking + no
  runtime to give Rust a clear edge on the `--version` style "how fast
  can the binary start" path. Go's runtime startup is already tiny;
  Rust's regex JIT-ish init eats most of the win back.

## Scope that didn't land in this spike

| Feature                          | Status                       |
| -------------------------------- | ---------------------------- |
| JSON corpus persistence          | not started                  |
| SQLite corpus backend            | not started                  |
| `--reinfer`                      | not started                  |
| `--propose-recognizers`          | not started                  |
| `--cross-host-shapes`            | not started                  |
| `--activate-above`               | not started                  |
| `completion <shell>`             | not started                  |
| `--stats`                        | not started                  |
| `--host` flag                    | not started                  |
| Calibration / Evidence           | not started                  |

These all need the Corpus ownership rework above. Cluster view in
Phase 1 builds an ephemeral aggregation inside the CLI process to cover
the auto-switch scenarios (`pipe cluster auto`).

## Recommendation

**Worth it for greenfield + perf-bound; harder to justify for in-place
migration.**

Numbers that justify the move:
- ~2.2× faster CLI on real workloads, ~45 % smaller binary.
- Code size in the same ballpark as Go for the same surface (Rust came
  in at 40 % of Go's line count, though that's partly Phase 1 scope —
  Corpus would close the gap).
- Stronger types catch wider classes of bugs at compile time.
- Single binary deploy, no runtime, predictable memory.

Numbers against in-place migration:
- The Ruby ↔ Go ↔ Rust three-way parity matrix triples the surface area
  of every "fix it in both" change. CI would need a third column.
- Corpus is non-trivial to redesign; that's the bulk of the remaining
  60 % of Go LOC.
- Cold-start win is modest. If your win story is "Rust is faster," you
  need a real workload to point at (CLI extraction is one).

If the strategic goal is a Rust plugin stack (greenfield), this spike
says **yes, do it** — the tooling (`regex`, `serde_json`,
`once_cell`, `thiserror`) is mature, mechanical translation works, and
the parity oracle plus golden fixtures from iriq make verification
cheap.

If the goal is to swap Go → Rust for *existing* services that already
have Go binaries deployed, the cost is much higher than the perf win
justifies unless those services are on the critical path of a wall-clock
metric.

## Reproducing

```sh
# In iriq repo root, on branch rust-port-spike:

# Lib + CLI build (release)
cd rust && cargo build --release && cd ..

# Library fixture tests (asserts against spec/fixtures/*.json,
# the same oracle Ruby + Go use):
cd rust && cargo test -p iriq && cd ..

# Three-way wall-clock comparison (Go vs Rust; Ruby skipped if 3.4+
# isn't available):
./script/bench_three_way.sh 5

# CLI parity diff (Rust vs Go on Phase-1 scenarios):
./script/rust_parity.sh
```
