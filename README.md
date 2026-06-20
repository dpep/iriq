Iriq
======
![Gem](https://img.shields.io/gem/dt/iriq?style=plastic)
[![codecov](https://codecov.io/gh/dpep/iriq/branch/main/graph/badge.svg)](https://codecov.io/gh/dpep/iriq)

**Iriq finds the *shape* of an IRI** — the structural template you get when you
erase the parts that vary and keep the parts that don't. `…/users/123` and
`…/users/999` are the same shape: `/users/{user_id}`. Feed iriq a pile of messy
URLs — a log file, a column of links, free-text prose — and it collapses them
into a small set of stable, deterministic route templates. Fifty thousand
distinct URLs become twelve shapes.

Everything iriq does — parsing, normalizing, classifying path and query
components, clustering, learning new patterns — exists to derive, render, or
group by that shape. The name is *IRI Query*: iriq queries an IRI for its
structure.

And it gets sharper the more you feed it. Point a *corpus* at a stream and
classifications improve as data flows in — high-churn slots get promoted to
placeholders, and whole types emerge that you can't see in any single URL (a
position that's always 100–599 is an HTTP status; one bounded to a dozen values
is an enum).

```sh
$ iriq -n https://foo.com/users/123
https://foo.com/users/{user_id}
```

It answers questions like:

- "What routes does this service actually expose?" (cluster a log file)
- "Which params are stable identifiers vs. churning IDs vs. enums?"
  (`--stats`)
- "Are these 50,000 distinct URLs really just 12 templates?" (clustering)
- "What does `/api/v1/users/abc-123-def` become as a route shape?"
  (`/api/{version}/users/{user_id}`)

Ships as both a **command-line tool** (`iriq`) and a **library** (Ruby and
Go — same behavior, enforced by parity tests).

## Quick start

```sh
$ iriq https://foo.com/users/123
# parse
original:      https://foo.com/users/123
kind:          url
scheme:        https
host:          foo.com
path_segments: ["users", "123"]
canonical:     https://foo.com/users/123

# normalize
https://foo.com/users/{user_id}

$ iriq -n https://foo.com/users/123
https://foo.com/users/{user_id}

$ iriq -n https://shop.com/pricing/usd?currency=eur
https://shop.com/pricing/USD?currency=EUR     # currency upcased
```

```sh
$ cat access.log | iriq                       # ≥ 10 IRIs → cluster view
[190] docs.example.com  /users/{user_id}
[186] app.example.com   /users/{user_id}
...

$ cat access.log | iriq --stats               # rolling aggregates
$ iriq ./access.log -n                        # auto-detect file → normalize each
$ iriq -J < access.log                        # newline-delimited JSON
$ iriq --corpus c.db < access.log             # persist into a SQLite corpus
```

Once a corpus has data, `-n` becomes corpus-informed:

```sh
$ for n in alice bob carol dave erin frank gina hank ivan jane; do
    iriq --corpus c.db https://foo.com/users/$n/profile >/dev/null
  done

$ iriq -n --corpus c.db https://foo.com/users/zoe/profile
https://foo.com/users/{user}/profile          # mechanical would keep "zoe"
```

### Two ways to normalize

Pick by the question you're asking:

- **`--canonical`** — clean up *this* URL, keeping the specifics.
  `HTTP://Foo.com:80/pull/42` → `http://foo.com/pull/42` (scheme/host
  lowercased, default port dropped; path and query left alone). Handy, but
  table stakes — plenty of libraries do it.
- **`--normalize`** *(the default)* — find the URL's *shape*, erasing the
  specifics into placeholders. `…/pull/42` → `…/pull/{id}`. This is the part
  you came to iriq for.

Same input, two questions: "what's the clean form of *this* URL?" vs "what
*kind* of URL is this?" The second is iriq's reason to exist.

## Install

The CLI ships four ways:

```sh
# Homebrew (recommended) — slim build, JSON corpora only
brew install dpep/tools/iriq

# Homebrew with the SQLite corpus backend
brew install dpep/tools/iriq-sqlite

# RubyGems — installs the CLI shim and the library
gem install iriq

# Go — slim build, JSON corpora only
go install github.com/dpep/iriq/cmd/iriq@latest

# Go with SQLite corpora — needs source checkout + build flag
git clone https://github.com/dpep/iriq && cd iriq
go build -tags sqlite -o $GOBIN/iriq ./cmd/iriq

# Rust — SQLite bundled by default, fastest of the three
cargo install iriq-cli
# (or from a source checkout): cd iriq/rust && cargo install --path iriq-cli
```

Three implementations of the same library, kept byte-identical by a CLI
parity harness in CI. The **slim** build (the default for Ruby + Go) reads
and writes JSON corpora; **SQLite** corpora need the SQLite-enabled build.
`iriq --help` prints a `Build:` line so you can tell which you're on.

| You installed via | Build | Corpus formats |
| --- | --- | --- |
| `brew install dpep/tools/iriq` | slim | `.json` |
| `brew install dpep/tools/iriq-sqlite` | SQLite | `.json` + `.db`/`.sqlite`/`.sqlite3` |
| `go install …/cmd/iriq@latest` | slim | `.json` |
| `go build -tags sqlite …` | SQLite | `.json` + `.db`/`.sqlite`/`.sqlite3` |
| `gem install iriq` | slim | `.json` |
| `gem install iriq` + `gem install sqlite3` | SQLite | `.json` + `.db`/`.sqlite`/`.sqlite3` (lazy-loaded) |
| `cargo install iriq-cli` | SQLite (bundled) | `.json` + `.db`/`.sqlite`/`.sqlite3` |

The Go SQLite build uses pure-Go `modernc.org/sqlite` (no cgo); the Rust
build statically links the C SQLite via `rusqlite` (bundled). Same on-disk
schema across all runtimes — a `.db` written by any binary opens in any
other.

For library use:

```ruby
# Gemfile
gem "iriq"
```

```go
import "github.com/dpep/iriq"
```

```toml
# Cargo.toml
[dependencies]
iriq = "0.29"
# or, for SQLite corpus support:
iriq = { version = "0.29", features = ["sqlite"] }
```

## Library quick start

```ruby
# Ruby
iri = Iriq.parse("https://foo.com/users/123")
iri.scheme         # => "https"
iri.host           # => "foo.com"
iri.path_segments  # => ["users", "123"]
iri.canonical      # => "https://foo.com/users/123"

Iriq.normalize("https://foo.com/users/123")
# => "https://foo.com/users/{user_id}"

Iriq.explain("https://foo.com/users/123/orders/456")
# => [
#      { value: "users",  type: :literal, variable: false, hint: nil       },
#      { value: "123",    type: :integer, variable: true,  hint: "user_id" },
#      { value: "orders", type: :literal, variable: false, hint: nil       },
#      { value: "456",    type: :integer, variable: true,  hint: "order_id" },
#    ]
```

```go
// Go (same surface)
iri, _ := iriq.Parse("https://foo.com/users/123")
iri.Scheme         // "https"
iri.Host           // "foo.com"
iri.PathSegments   // []string{"users", "123"}
iri.Canonical()    // "https://foo.com/users/123"

norm, _ := iriq.Normalize("https://foo.com/users/123")
// "https://foo.com/users/{user_id}"
```

```rust
// Rust (same surface)
use iriq::{parse, normalize, Extractor, Corpus};

let iri = parse("https://foo.com/users/123")?;
assert_eq!(iri.host, "foo.com");
assert_eq!(iri.path_segments, vec!["users", "123"]);
assert_eq!(iri.canonical(), "https://foo.com/users/123");

assert_eq!(normalize("https://foo.com/users/123")?,
           "https://foo.com/users/{user_id}");

// Streaming clustering against a persistent SQLite corpus.
let mut corpus = Corpus::open("c.db")?;
corpus.observe("https://foo.com/users/1")?;
corpus.save("c.db")?;
# Ok::<(), Box<dyn std::error::Error>>(())
```

These are two independent implementations of one spec — not a Go library
with a Ruby binding, nor a gem with a Go FFI. Ruby is the reference; Go
mirrors it, kept in lockstep by golden-JSON fixtures (`spec/fixtures/`) and a
CLI parity harness (`script/cli_parity.sh`), both gating CI. One version
stream covers both. See [CLAUDE.md](CLAUDE.md) for the dev workflow.

Pass `hints: false` to `Iriq.normalize` (or `PathShape`) for mechanical
placeholders (`{integer}` instead of `{user_id}`).

## RESTful hints

When a variable segment follows a literal one, Iriq derives a hint by
singularizing the literal and suffixing `_id` (or `_uuid` for UUIDs). This
is what produces `{user_id}` from `/users/123` and `{order_id}` from
`/orders/456`. Semantic types (`:version`, `:locale`, `:currency`, `:date`,
`:boolean`) skip the hint and surface as `{type}` — `/api/v1/status`
renders as `/api/{version}/status`, not the misleading `/api/{api_id}/status`.

Singularization uses `Iriq::Inflector`, which delegates to a swappable adapter:

```ruby
# Default: ActiveSupport::Inflector if `active_support/inflector` is loadable,
# otherwise a built-in adapter with rules adapted from ActiveSupport.

Iriq::Inflector.singularize("categories")  # => "category"
Iriq::Inflector.singularize("people")      # => "person"

# Override:
Iriq::Inflector.adapter = MyAdapter        # must respond to .singularize(String)
Iriq::Inflector.reset_adapter!
```

## Supported inputs

| Input                                | Notes                                            |
| ------------------------------------ | ------------------------------------------------ |
| `https://foo.com/users/123`          | Standard URL                                     |
| `foo.com/users/456`                  | Scheme-less; `https://` is assumed               |
| `urn:isbn:0451450523`                | URN — `scheme` and `nss` are populated           |
| `https://例え.テスト/こんにちは`         | Unicode IRI — display form preserved             |
| `HTTPS://Foo.com:443/A`              | Scheme + host lowercased; default port dropped   |
| `https://foo.com/a/./b/../c`         | Dot segments normalized                          |

## Segment classification

`Iriq::SegmentClassifier` returns one of:

- `:literal` — plain word (`users`, `orders`, `Profile`, `こんにちは`)
- `:integer` — pure digits below the timestamp range
- `:float` — decimal with digits on both sides (`3.14`, `-2.5`, `1.0`)
- `:boolean` — `true` / `false` (any case)
- `:version` — semver-ish with `v` prefix (`v1`, `v2.0.1`, `v1.2.3-beta`)
- `:locale` — BCP 47-ish (`en-US`, `fr_CA`, `zh-Hant`, bare `en`/`fr`/`ja`)
- `:currency` — ISO 4217 codes (`USD`, `EUR`, `JPY`)
- `:uuid` — `f47ac10b-58cc-4372-a567-0e02b2c3d479`
- `:date` — `2024-05-23`, `2024/05/23`, `20240523`, `05/23/2024`. Canonicalized to ISO in `--normalize` output.
- `:timestamp` — ISO 8601, or 10/13-digit UNIX epoch
- `:hash` — 32+ hex chars (md5 / sha)
- `:slug` — `my-cool-post`, `my_cool_post`
- `:ipv4` / `:ipv6` — collapsed to `{ip}` in normalized output
- `:url` — `https://...`, `ftp://...`, also scheme-less `foo.com/path`
- `:email` — `local@host.tld`
- `:phone` — E.164 (`+15551234567`) or NANP (`555-666-7777`, `(555) 666-7777`)
- `:jwt` — three base64url segments separated by dots
- `:mime` — `image/png`, `application/vnd.api+json`
- `:file` — `name.ext` for known extensions; per-kind grouping (image/document/data/...) via `SegmentClassifier.file_kind`
- `:color` — hex form (`#fff`, `#ffffff`, `#ffffff80`); kind via `SegmentClassifier.color_kind`
- `:coordinate` — `lat,lng` pair with plausible-range validation
- `:country` — ISO 3166-1 alpha-2 codes (`US`, `JP`, `GB`)
- `:base64` — standard base64 blobs with disambiguating `+`/`/`/`=`
- `:opaque_id` — short alphanumeric mix that doesn't fit elsewhere

Heuristics are deterministic and ordered — the first matching rule wins.
The classifier path is gated by cheap `String#include?` / `IndexByte`
guards so most segments skip most regex tests.

#### Types only the corpus can see

Four types never come from a single URL — they emerge from the *distribution*
of values a position has held across many observations:

| Type | Emerges when a position… |
| --- | --- |
| `:number` | holds both integers and floats |
| `:year` | holds integers that all land in 1900–2100 |
| `:http_status` | holds integers that all land in 100–599 |
| `:enum` | holds a small, bounded set of distinct values |

Mechanically, `200` is just an integer. Across ten thousand URLs where that
slot is always 100–599, it's an HTTP status. That's the corpus earning its
keep.

## Clustering

```ruby
clusterer = Iriq::Clusterer.new
clusterer.add("https://foo.com/users/123")
clusterer.add("https://foo.com/users/456")
clusterer.add("https://foo.com/users/789/orders/1")

clusterer.clusters.map(&:shape)
# => ["/users/{user_id}", "/users/{user_id}/orders/{order_id}"]

clusterer.clusters.first.segment_stats
# => [
#      { position: 0, stable: true,  values: { "users" => 2 } },
#      { position: 1, stable: false, values: { "123" => 1, "456" => 1 } },
#    ]

clusterer.explain("https://foo.com/users/999")
# => [
#      { value: "users", type: :literal, variable: false, hint: nil,       stable: true  },
#      { value: "999",   type: :integer, variable: true,  hint: "user_id", stable: false },
#    ]
```

A position the classifier *would* call variable but that is empirically
constant across all members of the cluster will be reported with
`stable: true, variable: false`.

## Corpus (streaming + learning)

For processing many identifiers — possibly an unbounded stream — use
`Iriq::Corpus`. It maintains rolling aggregates and per-(host, prefix)
frequency stats so classification improves as more data comes in.

```ruby
corpus = Iriq::Corpus.new

iris.each do |iri|
  obs = corpus.observe(iri)
  obs.fingerprint   # deterministic shape: "https://foo.com/users/{user_id}"
  obs.cluster       # the Iriq::Cluster this fell into
  obs.explanation   # per-segment annotations with corpus-informed classification
end

corpus.host_counts          # { "foo.com" => 1234, "bar.com" => 7 }
corpus.path_length_counts   # { 2 => 800, 3 => 434 }
corpus.fingerprint_counts   # shape → count
corpus.raw_shape_counts     # hint-free shape → count
corpus.clusters             # Iriq::Cluster instances
```

### Deterministic vs. corpus-informed normalization

```ruby
Iriq.normalize("https://foo.com/users/me")
# => "https://foo.com/users/me"   # mechanical: "me" is a literal

corpus.normalize("https://foo.com/users/me")
# => depends on what the corpus has seen
```

If many `/users/{integer}` paths flow in alongside a handful of
`/users/me`, the cluster `/users/me` is preserved (mechanical clustering
keeps literal routes distinct). If many *distinct literal handles*
(`/users/alice`, `/users/bob`, `/users/carol`, ...) flow in, the corpus
promotes that position to a `{user}` placeholder.

### Param hints

Param names guide normalization when a value's shape is too generic to
classify on its own:

```ruby
Iriq.normalize("https://foo.com/x?phone=unknown&email=tbd")
# => "https://foo.com/x?email={email}&phone={phone}"
```

Specific value types still win (`?phone=12345` stays `:integer`).

### Explainability

Each row of `corpus.explain(...)` carries a `classification:` symbol on
top of the deterministic fields:

| Classification              | Meaning                                              |
| --------------------------- | ---------------------------------------------------- |
| `:stable_literal`           | Literal value dominates this position                |
| `:variable_identifier`      | Classifier said variable (uuid, integer, etc.)       |
| `:rare_literal`             | Literal seen here, but not dominant                  |
| `:corpus_inferred_variable` | Classifier said literal, but position has high entropy |
| `:ambiguous`                | Insufficient signal — never seen, or mixed           |

### Re-runnable inference

A corpus persists the source-IRI log alongside the materialized views.
`corpus.reinfer` drops every view and replays the log through the
current classifier + reducers. Tune a threshold, swap in a different
classifier, or activate new Recognizers (below) — then `reinfer` to see
the new results without re-feeding URLs.

```ruby
corpus.observe(url) for url in stream
corpus.reinfer   # rebuilds host_counts, position_stats, clusters from log
```

CLI: `iriq --corpus c.db --reinfer`.

## Learning new types

Iriq doesn't just classify against a fixed list — it watches the stream and
*proposes new recognizers* for patterns it keeps seeing. Notice `ghp_…` or
`cus_…` recurring at a slug position and iriq will suggest a recognizer for it,
with evidence: coverage, host count, confidence. Proposals are never
auto-applied — you activate the ones you trust, and they persist with the
corpus. Human-in-the-loop by design.

### Proposals + activation

When a literal shape recurs enough, the corpus can propose a new
`Recognizer` for it. Today the only built-in strategy is
`PrefixUnderscoreId`, which detects `<prefix>_<alphanumeric>` patterns at
slug/opaque_id positions — the GitHub-PAT family (`ghp_…`), Stripe IDs
(`cus_…`), Twilio SIDs, etc.

```ruby
proposals = corpus.propose_recognizers
proposals.first.prefix             # "ghp_"
proposals.first.suggested_type     # :ghp
proposals.first.coverage           # 1.0  — fraction of position values matching
proposals.first.confidence         # 1.0  — coverage + cross-host boost (capped at 1.0)
proposals.first.observation_count  # 1247
proposals.first.hosts              # Set of hosts seen at
proposals.first.sample_values      # ["ghp_aaaa0001xyzzy", ...]
```

Proposal thresholds: `min_observations` (default 20), `min_coverage`
(0.7), `min_hosts` (1). The strategy interface is pluggable via
`Iriq::ProposalStrategy::DEFAULTS` so new detection rules drop in
without touching `Corpus`.

Promote a proposal to a live `Recognizer` and reinfer in one shot:

```ruby
recognizer = corpus.activate_proposal(proposals.first)
# ghp_xyz123 now classifies as :ghp, not :slug
# Existing observations have been re-classified via reinfer.
```

Activations persist with the corpus — reopen and they reapply. They
don't leak to other corpora using the module-level `SegmentClassifier::DEFAULT`;
the first activation swaps the corpus to a private classifier instance.

CLI:
- `iriq --corpus c.db --propose-recognizers` — print proposals (human or `--json`)
- `iriq --corpus c.db --propose-recognizers --activate-above 0.9` — auto-activate every proposal with confidence ≥ 0.9 and reinfer

### Cross-host shape learning

A route shape that recurs across multiple hosts is independent evidence
of a semantic pattern — two unrelated hosts inventing the same
`/users/{integer}` structure by accident is unlikely. `corpus.cross_host_shapes`
exposes this directly:

```ruby
corpus.cross_host_shapes(min_hosts: 2)
# => [
#   #<CrossHostShape shape="/users/{user_id}" hosts=#<Set:{"api.github.com","api.gitlab.com"}> observation_count=14203>,
#   ...
# ]
```

The same signal feeds back into proposal `confidence`: each additional
host beyond the first adds `0.05` to the score (capped at 1.0), so a
prefix proposed on 5 hosts is meaningfully stronger than the same
coverage seen on 1 host.

CLI: `iriq --corpus c.db --cross-host-shapes [--min-hosts N]`.

## Extracting IRIs from text

`Iriq::Extractor` is what powers pipe-mode in the CLI. Picks up explicit-
scheme URLs (`http`, `https`, `ftp`, `ws`, `wss`, `urn`) and `foo.com/path`-
style scheme-less URLs (small TLD allow-list, required path). Trims trailing
sentence punctuation iteratively and preserves balanced parens
(`https://en.wikipedia.org/wiki/Ruby_(programming_language)` stays intact;
`(see https://foo.com)` drops the outer paren).

```ruby
Iriq.extract("Visit https://foo.com today, also hit foo.com/users.")
# => [#<Iriq::Identifier https://foo.com>,
#     #<Iriq::Identifier https://foo.com/users>]

Iriq::Extractor.new(scheme_less: false).extract("hit foo.com/users today")
# => []
```

Known limitations (intentional):

- Comma is a URL boundary, so query strings like `?q=37.7,-122.4` truncate.
  Trade-off picked to keep CSV-shaped text working.
- No HTML entity decoding (`&amp;` stays as-is).
- Scheme-less mode skips bare hostnames without a path (too noisy in prose).

### Memory bounds

- Per-position `value_counts` is capped (`max_values_per_position`, default
  1000) — once full, `total` keeps growing but only existing keys count up.
- Cluster examples are capped at `Iriq::Cluster::MAX_EXAMPLES`.
- No raw IRI strings are retained outside the bounded cluster examples.

```ruby
Iriq::Corpus.new(max_values_per_position: 200)
```

## How it works

Under the shape sits one idea: **Position + Evidence**. A *Position* is a slot
in a host's structure — a typed path prefix, or a query-param name. *Evidence*
is everything the corpus has observed about that slot: which values, how often,
across how many hosts. Strings are observations; types are inferences drawn
from the pile. Shape is the surface you see; Position + Evidence is the engine
underneath. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full model.

## Object model

| Class                       | Responsibility                                       |
| --------------------------- | ---------------------------------------------------- |
| `Iriq::Parser`              | String → `Identifier`                                |
| `Iriq::Identifier`          | Structured fields + `canonical` reconstruction       |
| `Iriq::SegmentClassifier`   | Single segment → type symbol                         |
| `Iriq::PathShape`           | Segments → `/users/{user_id}` route shape            |
| `Iriq::SegmentHints`        | Derives `user_id`-style hints from neighbors         |
| `Iriq::Inflector`           | Singularization with swappable adapter (AS or built-in) |
| `Iriq::Normalizer`          | Identifier → canonical, shape-aware string           |
| `Iriq::Explanation`         | Per-segment `{value, type, variable, hint}` rows     |
| `Iriq::Cluster`             | One host + shape group, with examples & stats        |
| `Iriq::Clusterer`           | Many identifiers → `Cluster` set + explain          |
| `Iriq::PositionStats`       | Capped value/type frequencies for one position       |
| `Iriq::Observation`         | What `Corpus#observe` returns                        |
| `Iriq::Corpus`              | Streaming observer with rolling aggregates + learning |
| `Iriq::Extractor`           | Pulls IRIs out of free text (scheme-anchored)        |

## CLI reference

**Single input** — combined parse + normalize summary; trim with section
flags (`-p`, `-n`).

**Piped stdin** — extraction runs by default. Output auto-switches: small
inputs get a deduplicated URL list, larger inputs (≥ 10 IRIs) get the
cluster view via an ephemeral corpus.

`--corpus PATH` makes the corpus survive across invocations. The file
extension picks the storage backend:

- `.json` — atomically-written JSON file. Best for small corpora and
  when you want the data human-readable.
- `.db` / `.sqlite` / `.sqlite3` — SQLite with WAL journaling. Each
  observation is an incremental UPSERT, so multiple `iriq --corpus`
  processes can write concurrently.

Library: `Iriq::Corpus.open("c.db")` / `iriq.OpenCorpus("c.db")`
dispatches on the same extension rules. `corpus.save("export.json")`
exports any backend as JSON.

Flags:

| Flag                | Effect                                                  |
| ------------------- | ------------------------------------------------------- |
| `-p, --parse`       | Show parsed fields                                      |
| `-n, --normalize`   | Show the shape-normalized form                          |
| `-c, --canonical`   | Show the canonical form (no shape normalization)        |
| `-j, --json`        | Emit JSON                                               |
| `-J, --ndjson`      | Newline-delimited JSON (one object per line); implies `--json` |
| `-N, --no-hints`    | Use `{integer}` etc. instead of `{user_id}`             |
| `--no-scheme-less`  | Skip `foo.com/path`-style extraction (explicit-scheme only) |
| `--corpus PATH`     | Load/create a corpus at PATH (`.json` or `.db`/`.sqlite`/`.sqlite3`) |
| `--host MODE`       | Host-keying for clustering: `full` (default), `reg` strips subdomains, `none` ignores host |
| `--stats`           | Print rolling aggregates                                |
| `--reinfer`         | Drop the materialized views and replay the source-IRI log through the current classifier + reducers (rebuilds counts/clusters/positions from scratch) |
| `--propose-recognizers` | Scan observed values for shape patterns that recur enough to suggest a new Recognizer. Combine with `--json` for structured output |
| `--cross-host-shapes`   | List route shapes that recur across multiple hosts |
| `--min-observations N`  | Proposal threshold; default 20                    |
| `--min-coverage F`      | Proposal threshold; default 0.7                   |
| `--min-hosts N`         | Threshold for both proposals and cross-host shapes; default 1 / 2 respectively |
| `--activate-above F`    | With `--propose-recognizers`, auto-activate every proposal whose confidence is ≥ F |
| `completion bash\|zsh`  | Print shell completion script (Homebrew installs this automatically) |
| `-V, --version`     | Print version                                           |

A positional argument that doesn't parse as an IRI but IS an existing
file is read and extracted from automatically — `iriq ./access.log` and
`iriq /var/log/foo.log` Just Work. (Bare filenames like `README.md`
may still parse as a URL; pipe with `cat` to disambiguate.)

Exit codes: `0` success, `1` usage error, `2` parse error.

## Performance

Measured on the deterministic `IriGenerator` fixture (single thread,
Ruby 3.3.6 / Go 1.23 / Rust 1.94 on the same Linux container):

| Operation                | Ruby          | Go CLI       | Rust CLI     |
| ------------------------ | ------------- | ------------ | ------------ |
| `parse`                  | ~131k URLs/s  |              |              |
| `normalize`              | ~63k URLs/s   |              |              |
| `explain`                | ~94k URLs/s   |              |              |
| `extract` (prose)        | ~4.7 MB/s     |              |              |
| `Corpus#observe`         | ~33k URLs/s   |              |              |
| CLI wall-clock (2k URLs, `-n`)        | 373 ms | 43 ms  | **34 ms**    |
| CLI wall-clock (2k URLs, JSON corpus) | —      | 39 ms  | **29 ms**    |
| CLI wall-clock (2k URLs, SQLite)      | —      | 1240 ms | **120 ms**  |
| Release binary size (slim/sqlite)     | —      | 4 MB / 10 MB | **4.4 MB** (sqlite bundled) |

Rust pulls 1.2–10× ahead of Go depending on the backend; the SQLite win
is the largest because Rust binds bundled C SQLite via `rusqlite`
(cached prepared statements + `BEGIN IMMEDIATE` batching) while Go uses
pure-Go `modernc.org/sqlite`. Each runtime's CLI short-circuits regex
matches with cheap composition checks so common segments avoid most of
the regex chain.
Linear scaling holds through 100k observations; per-observation retained
memory amortizes to ~100 bytes at that scale. Memoization caches are
bounded by `CACHE_MAX = 10_000` (cleared when full).

Re-run anytime with:

```sh
bundle exec ruby script/benchmark.rb       # throughput
bundle exec ruby script/memory.rb          # retained memory + cache footprints
script/bench_compare.sh                    # Ruby vs Go CLI wall time
```

## Limitations (intentional)

Iriq does **not**:

- Implement RFC 3986, RFC 3987, or the WHATWG URL standard fully.
- Convert between Unicode (IRI) and punycode (URI) — the display form is
  preserved as-is.
- Percent-encode or decode path/query bytes. Bytes are kept as written.
- Validate scheme-specific structure beyond URL vs. URN.
- Resolve relative references against a base URL.
- Round-trip `canonical` back to the exact original byte-for-byte (whitespace
  is stripped, default ports are dropped, dot segments are collapsed).

For richer IRI handling, see `addressable`. Iriq's focus is the analysis
side: classification, normalization, and clustering — not a complete URL
implementation.

----
## Contributing

Yes please  :)

1. Fork it
1. Create your feature branch (`git checkout -b my-feature`)
1. Ensure the tests pass (`bundle exec rspec && go test ./...`)
1. If you changed library behavior, regenerate fixtures
   (`bundle exec ruby script/generate_fixtures.rb`) and check CLI parity
   (`script/cli_parity.sh`)
1. Commit your changes (`git commit -am 'awesome new feature'`)
1. Push your branch (`git push origin my-feature`)
1. Create a Pull Request
