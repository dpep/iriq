Iriq
======
![Gem](https://img.shields.io/gem/dt/iriq?style=plastic)
[![codecov](https://codecov.io/gh/dpep/iriq/branch/main/graph/badge.svg)](https://codecov.io/gh/dpep/iriq)

IRI extraction, normalization, and clustering.

Iriq pulls IRIs out of free text, parses them, normalizes them into
canonical shape-aware forms, classifies their path and query components,
and clusters similar identifiers — surfacing what's stable vs. unique.

Ships as both a **command-line tool** (`iriq`) and a **library** (Ruby and
Go — same behavior, enforced by parity tests).

## Install

The CLI is available three ways. Pick whichever fits your workflow:

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
```

The slim build supports `.json` corpus files; SQLite corpora (`.db` /
`.sqlite` / `.sqlite3`) require the SQLite-enabled build. Check what
your binary supports with `iriq --help` (look for the `Build:` line).
The Ruby gem loads the `sqlite3` gem lazily when a `.db` path is
opened — install it via `gem install sqlite3` if you need SQLite
corpora.

For library use, depend on whichever runtime you're working in:

```ruby
# Gemfile
gem "iriq"
```

```go
import "github.com/dpep/iriq"
```

## CLI quick start

```
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

$ cat access.log | iriq             # extract → URL list (or clusters at scale)
$ cat access.log | iriq --stats     # rolling aggregates
$ iriq ./access.log -n              # file auto-detected → normalize each found URL
```

Full CLI reference is below under [CLI](#cli).

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
#      { value: "users",  type: :literal,    variable: false, hint: nil        },
#      { value: "123",    type: :integer_id, variable: true,  hint: "user_id"  },
#      { value: "orders", type: :literal,    variable: false, hint: nil        },
#      { value: "456",    type: :integer_id, variable: true,  hint: "order_id" },
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

The Ruby gem is the reference implementation; Go mirrors its API and is
kept in sync via JSON fixtures plus a CLI parity harness. See
[CLAUDE.md](CLAUDE.md) for the dev process.

Pass `hints: false` to `Iriq.normalize` (or `PathShape`) for mechanical
placeholders (`{integer_id}` instead of `{user_id}`).

## RESTful hints

When a variable segment follows a literal one, Iriq derives a hint by
singularizing the literal and suffixing `_id` (or `_uuid` for UUIDs). This is
what produces `{user_id}` from `/users/123` and `{order_id}` from
`/orders/456`. Singularization uses `Iriq::Inflector`, which delegates to a
swappable adapter:

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
- `:integer` — pure digits below the timestamp range (`1`, `123`, `42`)
- `:float` — decimal with digits on both sides (`3.14`, `-2.5`, `1.0`)
- `:number` — corpus-only umbrella when ints and floats coexist at one position without a clear majority
- `:year` — 4-digit integer in 1900..2100 (`2026`, `1999`)
- `:boolean` — `true` / `false` (any case); `0`/`1` are caught by the `:enum` umbrella when they cluster
- `:version` — semver-ish with `v` prefix (`v1`, `v2.0.1`, `v1.2.3-beta`)
- `:locale` — BCP 47-ish with separator (`en-US`, `fr_CA`, `zh-Hant`)
- `:currency` — ISO 4217 codes from a ~35-entry allowlist (`USD`, `EUR`, `JPY`)
- `:uuid` — `f47ac10b-58cc-4372-a567-0e02b2c3d479`
- `:date` — `2024-05-23`, `2024/05/23`, `20240523`, `05/23/2024` (US, query-params only — slashes can't appear in path segments). Canonicalized to ISO in `--normalize` output.
- `:timestamp` — ISO 8601, or 10/13-digit UNIX epoch
- `:hash` — 32+ hex chars (md5 / sha)
- `:slug` — `my-cool-post`, `my_cool_post`
- `:ipv4` — dotted-quad with each octet 0..255 (`192.168.1.1`)
- `:ipv6` — full or compressed (`::1`, `2001:db8::1`, full 8-group form)
- `:url` — value-as-URL (`https://...`, `ftp://...`); useful for redirect params
- `:email` — `local@host.tld`
- `:enum` — corpus-only umbrella for bounded value sets (≥20 obs, ≤10 distinct)
- `:opaque_id` — short alphanumeric mix that doesn't fit elsewhere

Heuristics are deterministic and ordered — the first matching rule wins.

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
#      { value: "users", type: :literal,    variable: false, hint: nil,       stable: true  },
#      { value: "999",   type: :integer_id, variable: true,  hint: "user_id", stable: false },
#    ]
```

The clusterer combines classifier output with what it has actually observed:
a position the classifier *would* call variable but that is empirically
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

If many `/users/{integer_id}` paths flow in alongside a handful of
`/users/me`, the cluster `/users/me` is preserved (mechanical clustering
keeps literal routes distinct). If many *distinct literal handles*
(`/users/alice`, `/users/bob`, `/users/carol`, ...) flow in, the corpus
promotes that position to a `{user}` placeholder:

```ruby
%w[alice bob carol dave erin frank gina hank ivan jane].each do |name|
  corpus.observe("https://foo.com/users/#{name}/profile")
end

corpus.normalize("https://foo.com/users/alice/profile")
# => "https://foo.com/users/{user}/profile"
```

### Explainability

Each row of `corpus.explain(...)` (and `observation.explanation`) carries a
`classification:` symbol on top of the deterministic fields:

| Classification              | Meaning                                              |
| --------------------------- | ---------------------------------------------------- |
| `:stable_literal`           | Literal value dominates this position                |
| `:variable_identifier`      | Classifier said variable (uuid, integer, etc.)       |
| `:rare_literal`             | Literal seen here, but not dominant                  |
| `:corpus_inferred_variable` | Classifier said literal, but position has high entropy |
| `:ambiguous`                | Insufficient signal — never seen, or mixed           |

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

# Disable scheme-less:
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

## CLI

Installing the gem installs an `iriq` executable. Two main modes:

**Single input** — combined parse + normalize summary; trim with section
flags (`-p`, `-n`).

```
$ iriq foo.com/users/456
# parse
original:      foo.com/users/456
kind:          url
scheme:        https
host:          foo.com
path_segments: ["users", "456"]
canonical:     https://foo.com/users/456

# normalize
https://foo.com/users/{user_id}

$ iriq -n https://foo.com/users/123
https://foo.com/users/{user_id}
```

**Piped stdin** — extraction runs by default. Output auto-switches: small
inputs get a deduplicated URL list, larger inputs (≥ 10 IRIs) get the
cluster view via an ephemeral corpus. Section flags work too — emit one
normalized URL / parsed record per extracted IRI.

```
$ cat short.txt | iriq
[2] https://github.com/dpep/iriq
[1] https://foo.com/users

$ cat short.txt | iriq -n                     # normalized URL per line
https://github.com/dpep/iriq
https://foo.com/users

$ cat access.log | iriq                       # ≥ 10 IRIs → cluster view
[190] docs.example.com  /users/{user_id}
[186] app.example.com   /users/{user_id}
...

$ cat README.md | iriq --stats                # rolling aggregates
$ cat README.md | iriq cluster                # force cluster view
$ cat README.md | iriq --corpus c.json        # persist into a corpus
```

`--corpus PATH` makes the corpus survive across invocations. The file
extension picks the storage backend:

- `.json` — a single atomically-written JSON file (default). Best for small
  corpora and when you want the data human-readable.
- `.db` / `.sqlite` / `.sqlite3` — a SQLite database with WAL journaling.
  Each observation is an incremental UPSERT, so multiple `iriq --corpus`
  processes can write concurrently without clobbering each other, and the
  cost of opening doesn't scale with corpus size.

Once the corpus has data, `-n` becomes corpus-informed:

```
$ for n in alice bob carol dave erin frank gina hank ivan jane; do
    iriq --corpus c.db https://foo.com/users/$n/profile >/dev/null
  done

$ iriq -n --corpus c.db https://foo.com/users/zoe/profile
https://foo.com/users/{user}/profile         # mechanical would keep "zoe"
```

Library: `Iriq::Corpus.open("c.db")` (or `iriq.OpenCorpus("c.db")` in Go)
dispatches on the same extension rules. `corpus.save("export.json")`
exports any backend as JSON.

Flags:

| Flag                | Effect                                                  |
| ------------------- | ------------------------------------------------------- |
| `-p, --parse`       | Show parsed fields                                      |
| `-n, --normalize`   | Show the shape-normalized form                          |
| `-j, --json`        | Emit JSON                                               |
| `--ndjson`          | Newline-delimited JSON (one object per line); implies `--json` |
| `-N, --no-hints`    | Use `{integer_id}` etc. instead of `{user_id}`          |
| `--no-scheme-less`  | Skip `foo.com/path`-style extraction (explicit-scheme only) |
| `--corpus PATH`     | Load/create a corpus at PATH (`.json` or `.db`/`.sqlite`/`.sqlite3`) |
| `--stats`           | Print rolling aggregates                                |
| `-V, --version`     | Print version                                           |

A positional argument that doesn't parse as an IRI but IS an existing
file is read and extracted from automatically — `iriq ./access.log` and
`iriq /var/log/foo.log` Just Work. (Bare filenames like `README.md`
may still parse as a URL; pipe with `cat` to disambiguate.)

Exit codes: `0` success, `1` usage error, `2` parse error.

## Performance

Measured on the deterministic `IriGenerator` fixture (Ruby 3.4.9, single
thread):

| Operation                | Throughput   |
| ------------------------ | ------------ |
| `Iriq.parse`             | ~260k URLs/s |
| `Iriq.normalize`         | ~148k URLs/s |
| `Iriq.explain`           | ~205k URLs/s |
| `Iriq.extract` (prose)   | ~9.6 MB/s    |
| `Corpus#observe`         | ~80k URLs/s  |
| Corpus save/load (10k)   | ~135 ms      |

Linear scaling holds through 100k observations; per-observation retained
memory amortizes to ~100 bytes at that scale. Memoization caches are
bounded by `CACHE_MAX = 10_000` (cleared when full) — overhead is a few
hundred KB regardless of corpus size.

Re-run anytime with:

```
bundle exec script/benchmark.rb       # throughput
bundle exec script/memory.rb          # retained memory + cache footprints
```

## Limitations (intentional)

This is an MVP. Iriq does **not**:

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
## Go port

A Go implementation lives under [`go/`](go/) — same public surface, same
behavior, ~10× faster CLI on extraction-heavy workloads. The Ruby gem is
the reference; the Go port stays in sync via golden JSON fixtures
(`spec/fixtures/`) and a CLI parity harness (`script/cli_parity.sh`), both
checked in CI.

```go
import "github.com/dpep/iriq/go/iriq"

iri, _ := iriq.Parse("https://foo.com/users/123")
norm, _ := iriq.Normalize("https://foo.com/users/123")
// "https://foo.com/users/{user_id}"
```

See [`go/README.md`](go/README.md) for the full API table and porting workflow.

----
## Contributing

Yes please  :)

1. Fork it
1. Create your feature branch (`git checkout -b my-feature`)
1. Ensure the tests pass (`bundle exec rspec`)
1. If you changed library behavior, port the change to Go (or open an
   issue) and regenerate fixtures: `bundle exec ruby script/generate_fixtures.rb`
1. Commit your changes (`git commit -am 'awesome new feature'`)
1. Push your branch (`git push origin my-feature`)
1. Create a Pull Request
