###  0.30.2  (2026-06-23)
- Piped stdin and `--file` now **stream** the per-IRI sections (`-n`/`-p`/`-c`/`-e`) line by line, flushing each IRI as it's processed — `tail -f access.log | iriq -n` is live and memory stays bounded on huge inputs. Output is byte-identical to before; the aggregate views (deduped URL list, clusters, `--stats`) still read the whole input. Ruby, Go, and Rust.

###  0.30.1  (2026-06-21)
- Batch sections (`--normalize` etc.) are now corpus-informed when `--corpus` is supplied, matching single-input behavior.
- Added a CLI end-to-end test suite (sections, formats, batch/cluster, subcommands) and a `make check` Rust gate + pre-push hook.

###  0.30.0  (2026-06-21)
- Rust consolidated into a single crate (library + `iriq` binary) with SQLite always on by default — no separate sqlite build.
- Go moved into the `go/` subdirectory; import path is now `github.com/dpep/iriq/go`.

###  0.11.0  (2026-05-27)
- New classifier types: `:color` (hex form `#fff`/`#ffffff`/`#ffffff80`), `:coordinate` (`lat,lng` pair with plausible-range validation), `:country` (ISO 3166-1 alpha-2, allowlisted), `:base64` (≥16 chars with `+`/`/`/`=` to disambiguate from `:opaque_id`).
- `SegmentClassifier.color_kind(value)` / `ColorKind(value)` returns `:hex` for hex-shaped colors — placeholder for future named / rgb / hsl support, mirrors the file_kind pattern.
- Param-name hint map extended: `color`/`bg`/`fg`/`background`/`foreground` → `:color`, `coords`/`coordinates`/`geo`/`location`/`position`/`latlng` → `:coordinate`, `country`/`country_code`/`nation` → `:country`.
- `-J` is now a short alias for `--ndjson` (combinable: `iriq -nJ < file`).
- New CLI `-e/--explain` flag — annotated normalization trace. For each path segment / query param, shows the value, type, output (placeholder or canonical value), and notes for every non-obvious transformation (hint suppression for semantic types, currency upcase, IP umbrella collapse, canonical date, param-name lift). JSON via `-e -j` returns the same structure.
- Library API: `Iriq::Trace.for(input)` (Ruby) / `iriq.Trace(input)` (Go) returns the same trace data structure.
- Classifier perf: each regex test is now gated on a cheap composition check (`String#include?` / `IndexByte` / `size`) so a literal like `"users"` skips ~20 regex matches instead of walking the full chain. Measured: Ruby normalize +12%, extract +27%; Go CLI wall time -25%.

###  0.10.0  (2026-05-27)
- New classifier type `:file` — `name.ext` shape where `ext` is in a curated allowlist spanning image / document / data / text / web / audio / video / archive / code kinds. `image.png` and `report.pdf` classify as `:file` instead of falling through to `:opaque_id`. The per-extension kind (`:image`, `:document`, etc.) is surfaced via `SegmentClassifier.file_kind(value)` / `FileKindOf(value)` for verbose displays.
- `Cluster#param_summary` adds `:kind_distribution` for `:file`-typed params — buckets observed values by kind. Best-effort: only reflects values within the tracking cap.
- New phone format: NANP-style `555-666-7777`, `555.666.7777`, `(555) 666-7777`. Leading area-code + exchange digits constrained to 2-9 so dotted version strings / digit blobs don't shadow. The `+` E.164 form still covers international.
- Param-name hints — when a value's type is generic (`:literal`, `:opaque_id`, `:slug`), the param name can supply the type. `?phone=unknown` becomes `{phone}` and `?email=tbd` becomes `{email}`. Hint map covers phone/email/locale/currency/url/jwt/mime variations. Specific value types (e.g. `?phone=12345` → `:integer`) still win.

###  0.9.0  (2026-05-27)
- Semantic types (`:version`, `:locale`, `:currency`, `:date`, `:boolean`, `:timestamp`, etc.) now surface as `{type}` placeholders instead of being run through the noun-singularize hint. `/api/v1/status` renders `/api/{version}/status` rather than the misleading `/api/{api_id}/status`. Only ID-shaped types (`:integer`, `:uuid`, `:hash`, `:opaque_id`, `:slug`) keep the `{noun_id}` form.
- `--normalize` collapses `:ipv4` and `:ipv6` to `{ip}` in placeholder form (previously rendered as `{ipv4}` / `{ipv6}`). The classifier still tracks the specific family; cluster summary keeps the distinct types.
- `--normalize` canonicalizes currency segments and params to ISO 4217 upper case — `/pricing/usd` → `/pricing/USD`, `?currency=eur` → `?currency=EUR`. Mirrors the existing date canonicalization (`canonical_currencies: true` flag on `PathShape`).
- `LOCALE_RE` tightened: the region/script portion now caps at 2-4 alphanumeric chars and the language portion is validated against the ISO 639-1 allowlist — `by-locale` no longer wrongly classifies as `:locale`.
- New classifier types: `:phone` (E.164 — `+` then 7-15 digits with optional separators), `:jwt` (three base64url segments separated by dots), `:mime` (RFC 2046 top-level type + subtype, e.g. `image/png`, `application/vnd.api+json`).
- New corpus-promoted type `:http_status` — integer positions whose observed range falls inside 100..599 with ≥2 distinct values and ≥5 samples get promoted. Same range-analysis pattern as `:year`.
- Scheme-less URL detection: query values like `?redirect=foo.com/path` classify as `:url`. Requires a dotted host with a TLD-like ≥2-letter suffix followed by a slash, so `image.png` stays as `:opaque_id`.
- `Cluster#param_summary` adds two new fields:
  - `:value_distribution` — fractions per tracked value, for `:boolean` and `:enum` positions (e.g. `{ "true" => 0.97, "false" => 0.03 }`). Same data already in `value_counts`, surfaced as ratios.
  - `:subtype_distribution` — int-vs-float split for `:number` positions (e.g. `{ integer: 0.4, float: 0.6 }`).
- `:boolean` now wins over `:enum` when the dominant type is boolean — a position of pure `true`/`false` stays `:boolean` rather than being demoted to a 2-value enum.

###  0.8.0  (2026-05-27)
- **Breaking**: `:numeric` umbrella renamed to `:number` (Ruby) / `TypeNumeric` → `TypeNumber` (Go). Same semantics.
- New classifier types: `:boolean` (`true`/`false`, any case), `:version` (`v1`, `v2.0.1`, `v1.2.3-beta` — requires the `v` prefix), `:locale` (BCP 47-ish full forms like `en-US`/`fr_CA`, plus bare 2-letter language codes from an inline ISO 639-1 allowlist of ~55 entries — `en`, `fr`, `ja`, etc.), `:currency` (3-letter codes from an inline ISO 4217 allowlist of ~35 entries).
- `:year` is now corpus-only: an `:integer` position whose observed min/max land in 1900..2100 with ≥2 distinct values gets promoted. A single 4-digit integer in isolation classifies as `:integer` — only range analysis across observations is reliable.
- `PositionStats` now tracks `numeric_min` / `numeric_max` / `numeric_sum` / `numeric_count` for `:integer`/`:float` observations. `Cluster#param_summary` surfaces `min` / `max` / `avg` on any param with numeric observations.
- Shape-y variable types (`:version`, `:locale`, `:currency`, `:boolean`) now respect the stable-literal rule: a single dominant value at a position (`v1` only across many observations) stays as the literal `v1` instead of being placeholdered as `{version}`. High cardinality at the same position falls back to `{version}` / `{locale}` / etc. as expected.
- 0/1 booleans still classify as `:integer` individually; the existing `:enum` umbrella catches `?flag=0` / `?flag=1` patterns when they cluster.

###  0.7.0  (2026-05-27)
- **Breaking**: `:integer_id` classifier type renamed to `:integer` (Ruby) / `TypeIntegerID` → `TypeInteger` (Go). The "ID" semantics live in the hints layer (which still produces `{user_id}` placeholders); the classifier now reflects pure shape. Update any direct `.classify(...) == :integer_id` checks, dump-file consumers, and persisted corpora — the type symbol changed in `type_counts` and raw shape strings (e.g. `/users/{integer_id}` → `/users/{integer}`).
- New `:enum` umbrella (corpus-only): when a param has a small bounded set of repeated values (default ≥20 observations, ≤10 distinct, each ≥2 occurrences, ≥95% coverage), `Cluster#param_type` returns `:enum` and `param_summary` includes the value list under `:values`. Normalize output keeps the `{enum}` placeholder — values aren't inlined.
- `iriq --host=full|registrable|reg|none` CLI flag plumbs `Corpus#host_strategy` from the command line. `reg` is a short alias for `registrable`.

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
