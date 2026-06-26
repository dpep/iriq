Iriq
======
[![codecov](https://codecov.io/gh/dpep/iriq/branch/main/graph/badge.svg)](https://codecov.io/gh/dpep/iriq)

**Iriq finds the *shape* of a URL** — the structural template you get when you
erase the parts that vary and keep the parts that don't. `…/users/123` and
`…/users/999` are the same shape: `/users/{user_id}`. Feed iriq a pile of messy
URLs — a log file, a column of links, free-text prose — and it collapses them
into a small set of stable, deterministic route templates. Fifty thousand
distinct URLs become twelve shapes.

(If you know URLs, you already know IRIs — an **IRI** is just the bigger family.
It covers the everyday `https://…` URL, plus URNs like `urn:isbn:0451450523`,
other schemes like `mailto:`, and internationalized addresses with non-ASCII
characters like `https://例え.jp/パス`. Formally it's the Unicode superset of
URI/URL. The name is *IRI Query*: iriq queries an IRI for its structure.)

Everything iriq does — parsing, normalizing, classifying path and query
components, clustering, learning new patterns — exists to derive, render, or
group by that shape.

And it gets sharper the more you feed it. A *corpus* — on by default — records
what it sees and improves classifications as data flows in: high-churn slots get
promoted to placeholders, and whole types emerge that no single URL can reveal (a
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

Iriq ships as a **command-line tool** (`iriq`) and a **Rust library**.

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
$ iriq --corpus team.db < access.log          # use a specific corpus file
```

Per-IRI output (`-n`, `-p`, `-c`, `-J`) streams — each line is read, classified,
and flushed as it arrives, so iriq works on an unbounded live feed:

```sh
$ tail -f access.log | iriq -n                # one shape per line, as logs land
$ tail -f access.log | iriq -J                # same, as newline-delimited JSON
```

**Every invocation observes into a persistent corpus by default**, so iriq gets
smarter the more you run it. The corpus-only types — `enum`, `http_status`,
`year`, `number` — emerge from the *distribution* of values a position has held,
something no single URL can show. The cluster view and `--stats` report the
learned type per position:

```sh
# Feed a stream where ?status only ever holds a couple of words:
$ for n in $(seq 1 20); do
    iriq --corpus demo.db "https://api.foo.com/orders/$n?status=open"   >/dev/null
    iriq --corpus demo.db "https://api.foo.com/orders/$n?status=closed" >/dev/null
  done

# Ask what it learned. ?status is now an enum — a verdict no single URL
# could support, since one URL shows only one value:
$ iriq --corpus demo.db cluster
[40] api.foo.com  /orders/{order_id}
    https://api.foo.com/orders/1?status=open
    https://api.foo.com/orders/1?status=closed
    https://api.foo.com/orders/2?status=open
    + 37 more
    status  enum  (2 distinct, 100%)
```

These learned types also flow into normalized output: once the corpus has pegged
`?status` as an enum, `iriq -n …?status=open` renders `?status={enum}`.

The default corpus lives at `$XDG_DATA_HOME/iriq/default.db` (Linux),
`~/Library/Application Support/iriq/default.db` (macOS), or
`%LOCALAPPDATA%/iriq/default.db` (Windows). First-run creation prints a
one-line stderr notice. Three knobs control it:

```sh
$ iriq --no-corpus -n https://foo.com/users/123    # one-shot ephemeral; or -C
$ IRIQ_NO_CORPUS=1 iriq -n https://foo.com/users/123  # globally disable
$ IRIQ_CORPUS=/path/to/work.db iriq -n https://foo.com/users/123  # override path
$ iriq --corpus team.db https://foo.com/users/123  # explicit override (wins over env)
$ iriq --reset                                     # delete the corpus DB and exit
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

```sh
# Homebrew (recommended)
brew install dpep/tools/iriq

# Cargo, from crates.io
cargo install iriq

# Cargo, from a source checkout
cargo install --path rust/iriq
```

One crate ships both the library and the `iriq` binary. Corpora persist to
SQLite (bundled, WAL) out of the box — nothing to flag, install, or rebuild.

## Use it as a Rust library

```sh
cargo add iriq
```

```rust
use iriq::{parse, normalize, Corpus};

let iri = parse("https://foo.com/users/123")?;
iri.host;             // "foo.com"
iri.path_segments;    // ["users", "123"]
iri.canonical();      // "https://foo.com/users/123"

normalize("https://foo.com/users/123")?;   // "https://foo.com/users/{user_id}"

// Streaming clustering against a persistent corpus.
let mut corpus = Corpus::open("c.db")?;
corpus.observe("https://foo.com/users/1")?;
corpus.save("c.db")?;
```

Full API on [docs.rs/iriq](https://docs.rs/iriq); see the
[crate README](rust/iriq/README.md) for the library tour.

## Segment classification

Iriq classifies each path/query segment into one of ~25 types — the first
matching rule wins, and heuristics are deterministic:

- `literal` — plain word (`users`, `orders`, `Profile`, `こんにちは`)
- `integer` — pure digits below the timestamp range
- `float` — decimal with digits on both sides (`3.14`, `-2.5`, `1.0`)
- `boolean` — `true` / `false` (any case)
- `version` — semver-ish with `v` prefix (`v1`, `v2.0.1`, `v1.2.3-beta`)
- `locale` — BCP 47-ish (`en-US`, `fr_CA`, `zh-Hant`, bare `en`/`fr`/`ja`)
- `currency` — ISO 4217 codes (`USD`, `EUR`, `JPY`)
- `uuid` — `f47ac10b-58cc-4372-a567-0e02b2c3d479`
- `date` — `2024-05-23`, `2024/05/23`, `20240523`, `05/23/2024`. Canonicalized to ISO in `--normalize` output.
- `timestamp` — ISO 8601, or 10/13-digit UNIX epoch
- `hash` — 32+ hex chars (md5 / sha)
- `slug` — `my-cool-post`, `my_cool_post`
- `ipv4` / `ipv6` — collapsed to `{ip}` in normalized output
- `url` — `https://...`, `ftp://...`, also scheme-less `foo.com/path`
- `email` — `local@host.tld`
- `phone` — E.164 (`+15551234567`) or NANP (`555-666-7777`, `(555) 666-7777`)
- `jwt` — three base64url segments separated by dots
- `mime` — `image/png`, `application/vnd.api+json`
- `file` — `name.ext` for known extensions; per-kind grouping (image/document/data/...)
- `color` — hex form (`#fff`, `#ffffff`, `#ffffff80`)
- `coordinate` — `lat,lng` pair with plausible-range validation
- `country` — ISO 3166-1 alpha-2 codes (`US`, `JP`, `GB`)
- `base64` — standard base64 blobs with disambiguating `+`/`/`/`=`
- `opaque_id` — short alphanumeric mix that doesn't fit elsewhere

### RESTful hints

When a variable segment follows a literal one, iriq derives a hint by
singularizing the literal and suffixing `_id` (or `_uuid` for UUIDs). That's
what produces `{user_id}` from `/users/123` and `{order_id}` from `/orders/456`.
Semantic types (`version`, `locale`, `currency`, `date`, `boolean`) skip the
hint and surface as `{type}` — `/api/v1/status` renders as `/api/{version}/status`,
not the misleading `/api/{api_id}/status`. Pass `-N` / `--no-hints` for
mechanical placeholders (`{integer}` instead of `{user_id}`).

### Types only the corpus can see

Four types never come from a single URL — they emerge from the *distribution*
of values a position has held across many observations:

| Type | Emerges when a position… |
| --- | --- |
| `number` | holds both integers and floats |
| `year` | holds integers that all land in 1900–2100 |
| `http_status` | holds integers that all land in 100–599 |
| `enum` | holds a small, bounded set of distinct values |

Mechanically, `200` is just an integer. Across ten thousand URLs where that
slot is always 100–599, it's an HTTP status. That's the corpus earning its keep.

## Corpus (streaming + learning)

The corpus maintains rolling aggregates and per-(host, prefix) frequency stats,
so classification improves as more data comes in — handy for an unbounded stream
of identifiers. The default corpus already persists; `--corpus PATH` points iriq
at a specific file instead, to keep separate corpora or share one across runs.

A `.db` / `.sqlite` / `.sqlite3` path is stored in SQLite (WAL journaling, incremental
UPSERTs — multiple `iriq --corpus` processes can write concurrently); a
`.json` path writes a plain JSON file instead.

### Re-runnable inference

A corpus persists the source-IRI log alongside the materialized views.
`--reinfer` drops every view and replays the log through the current classifier
and reducers. Tune a threshold, swap in a different classifier, or activate new
recognizers (below) — then reinfer to see the new results without re-feeding
URLs.

```sh
$ iriq --corpus c.db --reinfer
```

## Learning new types

Iriq doesn't just classify against a fixed list — it watches the stream and
*proposes new recognizers* for patterns it keeps seeing. Notice `ghp_…` or
`cus_…` recurring at a slug position and iriq will suggest a recognizer for it,
with evidence: coverage, host count, confidence. Proposals are never
auto-applied — you activate the ones you trust, and they persist with the
corpus. Human-in-the-loop by design.

```sh
# Print proposals (human-readable, or --json)
$ iriq --corpus c.db --propose-recognizers

# Auto-activate every proposal with confidence ≥ 0.9, then reinfer
$ iriq --corpus c.db --propose-recognizers --activate-above 0.9
```

### Cross-host shape learning

A route shape that recurs across multiple hosts is independent evidence of a
semantic pattern — two unrelated hosts inventing the same `/users/{integer}`
structure by accident is unlikely.

```sh
$ iriq --corpus c.db --cross-host-shapes [--min-hosts N]
```

The same signal feeds back into proposal `confidence`: each additional host
beyond the first adds `0.05` to the score (capped at 1.0), so a prefix proposed
on 5 hosts is meaningfully stronger than the same coverage seen on 1 host.

## Extracting IRIs from text

Pipe-mode extraction picks up explicit-scheme URLs (`http`, `https`, `ftp`,
`ws`, `wss`, `urn`) and `foo.com/path`-style scheme-less URLs (small TLD
allow-list, required path). It trims trailing sentence punctuation and preserves
balanced parens (`https://en.wikipedia.org/wiki/Ruby_(programming_language)`
stays intact; `(see https://foo.com)` drops the outer paren).

Known limitations (intentional):

- Comma is a URL boundary, so query strings like `?q=37.7,-122.4` truncate.
  Trade-off picked to keep CSV-shaped text working.
- No HTML entity decoding (`&amp;` stays as-is).
- Scheme-less mode skips bare hostnames without a path (too noisy in prose).

Disable scheme-less extraction with `--no-scheme-less`.

## How it works

Under the shape sits one idea: **Position + Evidence**. A *Position* is a slot
in a host's structure — a typed path prefix, or a query-param name. *Evidence*
is everything the corpus has observed about that slot: which values, how often,
across how many hosts. Strings are observations; types are inferences drawn from
the pile. Shape is the surface you see; Position + Evidence is the engine
underneath. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full model.

## CLI reference

**Single input** — combined parse + normalize summary; trim with section flags
(`-p`, `-n`).

**Piped stdin** — extraction runs by default. Output auto-switches: small inputs
get a deduplicated URL list, larger inputs (≥ 10 IRIs) get the cluster view via
an ephemeral corpus.

| Flag                | Effect                                                  |
| ------------------- | ------------------------------------------------------- |
| `-p, --parse`       | Show parsed fields                                      |
| `-n, --normalize`   | Show the shape-normalized form                          |
| `-c, --canonical`   | Show the canonical form (no shape normalization)        |
| `-j, --json`        | Emit JSON                                               |
| `-J, --ndjson`      | Newline-delimited JSON (one object per line); implies `--json` |
| `-N, --no-hints`    | Use `{integer}` etc. instead of `{user_id}`             |
| `--no-scheme-less`  | Skip `foo.com/path`-style extraction (explicit-scheme only) |
| `--corpus PATH`     | Use a specific corpus file (`.json` or `.db`/`.sqlite`/`.sqlite3`). Overrides the default |
| `-C, --no-corpus`   | Disable corpus persistence for this invocation (same as `IRIQ_NO_CORPUS=1`) |
| `--reset`           | Delete the corpus database and exit                     |
| `--host MODE`       | Host-keying for clustering: `full` (default), `reg` strips subdomains, `none` ignores host |
| `--stats`           | Print rolling aggregates                                |
| `--reinfer`         | Drop the materialized views and replay the source-IRI log through the current classifier + reducers |
| `--propose-recognizers` | Scan observed values for shape patterns that recur enough to suggest a new recognizer. Combine with `--json` for structured output |
| `--cross-host-shapes`   | List route shapes that recur across multiple hosts |
| `--min-observations N`  | Proposal threshold; default 20                    |
| `--min-coverage F`      | Proposal threshold; default 0.7                   |
| `--min-hosts N`         | Threshold for both proposals and cross-host shapes; default 1 / 2 respectively |
| `--activate-above F`    | With `--propose-recognizers`, auto-activate every proposal whose confidence is ≥ F |
| `completion bash\|zsh`  | Print shell completion script (Homebrew installs this automatically) |
| `-V, --version`     | Print version                                           |

Environment variables:

| Variable             | Effect                                                  |
| -------------------- | ------------------------------------------------------- |
| `IRIQ_CORPUS=PATH`   | Set the corpus path (overrides the default)             |
| `IRIQ_NO_CORPUS=1`   | Disable the default corpus (equivalent to `-C`)         |

A positional argument that doesn't parse as an IRI but IS an existing file is
read and extracted from automatically — `iriq ./access.log` and
`iriq /var/log/foo.log` Just Work. (Bare filenames like `README.md` may still
parse as a URL; pipe with `cat` to disambiguate.)

Exit codes: `0` success, `1` usage error, `2` parse error.

## Limitations (intentional)

Iriq does **not**:

- Implement RFC 3986, RFC 3987, or the WHATWG URL standard fully.
- Convert between Unicode (IRI) and punycode (URI) — the display form is
  preserved as-is.
- Percent-encode or decode path/query bytes. Bytes are kept as written.
- Validate scheme-specific structure beyond URL vs. URN.
- Resolve relative references against a base URL.
- Round-trip `canonical` back to the exact original byte-for-byte (whitespace is
  stripped, default ports are dropped, dot segments are collapsed).

Iriq's focus is the analysis side: classification, normalization, and clustering
— not a complete URL implementation.

----
## Contributing

Yes please  :)

1. Fork it
1. Create your feature branch (`git checkout -b my-feature`)
1. Ensure the tests pass (`cd rust && cargo test`)
1. Commit your changes (`git commit -am 'awesome new feature'`)
1. Push your branch (`git push origin my-feature`)
1. Create a Pull Request
