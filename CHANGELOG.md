###  0.6.0  (2026-05-27)
- New classifier types: `:ipv4`, `:ipv6`, `:url`, `:email` (Ruby) / `TypeIPv4`, `TypeIPv6`, `TypeURL`, `TypeEmail` (Go). Slotted before the generic `:opaque_id` / `:literal` catch-alls so URL params like `?redirect=https://foo.com/...`, `?email=alice@example.com`, `?ip=192.168.1.1`, `?gateway=fe80::1` get distinct types instead of falling through.
- IPv4 validates octets ≤ 255 — out-of-range dotted-quads fall back to `:opaque_id`.
- IPv6 accepts the full eight-group form and any compressed form containing `::`. IPv4-mapped variants (`::ffff:192.0.2.1`) are not recognized.

###  0.5.0  (2026-05-27)
- Float values now classify as `:float` instead of falling through to `:opaque_id` (Ruby `:float` / Go `TypeFloat`). Regex requires digits on both sides of the decimal — `3.14`, `-2.5`, `1.0` match; `.5`, `1.`, `1e10` do not.
- New `:numeric` umbrella (corpus-only): when a cluster sees both `:integer_id` and `:float` observations at the same param with neither subtype hitting the 80% confidence threshold, the param surfaces as `:numeric` in `param_summary` and renders as `{numeric}` in `Corpus#normalize` output. The classifier itself never returns `:numeric` directly — individual values are always specifically int or float.
- `Corpus.new(host_strategy: ...)` knob controls how host is keyed into clusters: `:full` (default, unchanged), `:registrable` (strip subdomains, so `api.foo.com` and `app.foo.com` cluster as `foo.com`), `:none` (ignore host, group all observations by shape alone). `:registrable` uses an inline allowlist of ~70 common multi-label TLDs (`co.uk`, `com.au`, `co.jp`, etc.) — niche multi-label suffixes like `.priv.no` will be over-stripped.

###  0.4.0  (2026-05-27)
- Query-param clustering: each `Cluster` now tracks per-param presence, value cardinality, and type via `param_stats`. Surfaced on `cluster.to_h[:params]` (and the JSON cluster view), persisted in both JSON and SQLite backends.
- `Corpus#normalize` (Ruby) / `Corpus.NormalizeIdentifier` (Go) now include query params, rendered with corpus-informed types when available (falls back to mechanical classification otherwise).
- New `corpus.params_for(url)` / `Corpus.ParamsFor(url)` — returns the inferred params for the cluster `url` would fall into. Useful for "what params might this URL accept?" tooling.
- Date detection expanded to include `YYYY/MM/DD` and `YYYYMMDD` (with year/month/day sanity bounds) alongside the existing `YYYY-MM-DD`.
- `SegmentClassifier.canonical_date(value)` / `CanonicalDate(value)` returns the ISO form for any recognized date.
- `--normalize` output canonicalizes recognized date values to `YYYY-MM-DD` (path segments and query params). Cluster keys still use `{date}` placeholders so dated routes still group together.
- `PositionStats::DEFAULT_MAX_VALUES` is now the value cap for `cluster.param_stats[name]` too.

###  0.3.0  (2026-05-25)
- Go: SQLite backend is now opt-in via `-tags sqlite`. Default `go install` and the `iriq` Homebrew formula ship a slim binary (~30% smaller) with JSON corpora only. SQLite users compile with `-tags sqlite` or install `dpep/tools/iriq-sqlite`.
- Makefile: `release` / `release-sqlite` targets strip debug symbols and use `-trimpath` for reproducible builds.
- CLI: `iriq --help` reports the active build (slim vs sqlite).
- Slim build returns a friendly error when a `.db` corpus path is opened, pointing at the iriq-sqlite formula.
- `PositionStats::DEFAULT_MAX_VALUES` / `DefaultMaxValuesPerPosition` raised from 1000 → 5000. Existing corpora keep whatever cap they were created with (the cap is persisted in the dump / SQLite meta table); only freshly-constructed corpora pick up the new default.

###  0.2.0  (2026-05-25)
- Corpus storage backends: JSON (default) and SQLite, dispatched by file extension
- Go: `iriq.OpenCorpus(path)`; Ruby: `Iriq::Corpus.open(path)`
- SQLite backend: incremental UPSERTs, WAL mode, concurrent-safe via busy_timeout + BEGIN IMMEDIATE; checkpoints on close so the WAL sidecar doesn't grow unbounded
- Batch mode: `corpus.batch { ... }` (Ruby) / `corpus.Batch(fn)` (Go) wraps many observations in one transaction
- Clusterer now wraps the in-memory Storage backend; only one cluster code path
- script/bench_storage.sh — JSON vs SQLite timing across single-process, incremental, and concurrent workloads
- **Breaking (Go)**: `Corpus.HostCounts` / `PathLengthCounts` / `RawShapeCounts` / `FingerprintCounts` are methods now, not fields

###  0.1.0  (2026-05-24)
- CLI: auto-detect file argument, retire --extract flag
- CLI: section flags work in pipe mode + clean up help text
- script/memory.rb — track retained memory + cache footprints
- Perf: classifier + inflector memoization, singleton classifier, combined extractor regex
- Perf: derive SegmentHints once per Corpus.observe (~2x faster)
- script/benchmark.rb — measure the main hot paths
- README: replace fabricated example numbers with real fixture output
- Pipe mode: extraction by default, auto-switch to cluster view at scale
- Iriq::Extractor — pull IRIs out of free text
- E2E spec: pipe IriGenerator stream through real iriq binary
- IriGenerator fixture + popular-outlier heuristic
- CLI --corpus persistence, pipe batch mode, --stats, E2E specs
- Streaming Corpus with rolling stats and learning
- RESTful hints, flag-based CLI, swappable inflector

###  0.0.1  (2026-05-24)
 - prototype
