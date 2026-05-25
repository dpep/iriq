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
