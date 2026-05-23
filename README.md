Iriq
======
![Gem](https://img.shields.io/gem/dt/iriq?style=plastic)
[![codecov](https://codecov.io/gh/dpep/iriq/branch/main/graph/badge.svg)](https://codecov.io/gh/dpep/iriq)

Semantic IRI / URI / URL / URN normalization and clustering for Ruby.

Iriq parses resource identifiers, normalizes them into canonical IRI-like
forms, classifies path and query components, clusters similar identifiers,
and explains which parts are stable vs. unique.

```ruby
require "iriq"
```

## Quick start

```ruby
iri = Iriq.parse("https://foo.com/users/123")
iri.scheme         # => "https"
iri.host           # => "foo.com"
iri.path_segments  # => ["users", "123"]
iri.canonical      # => "https://foo.com/users/123"

Iriq.normalize("https://foo.com/users/123")
# => "https://foo.com/users/{integer_id}"

Iriq.explain("https://foo.com/users/123/orders/456")
# => [
#      { value: "users",  type: :literal,    variable: false },
#      { value: "123",    type: :integer_id, variable: true  },
#      { value: "orders", type: :literal,    variable: false },
#      { value: "456",    type: :integer_id, variable: true  },
#    ]
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
- `:integer_id` — pure digits below the timestamp range (`1`, `123`, `42`)
- `:uuid` — `f47ac10b-58cc-4372-a567-0e02b2c3d479`
- `:date` — `2024-05-23`
- `:timestamp` — ISO 8601, or 10/13-digit UNIX epoch
- `:hash` — 32+ hex chars (md5 / sha)
- `:slug` — `my-cool-post`, `my_cool_post`
- `:opaque_id` — short alphanumeric mix that doesn't fit elsewhere

Heuristics are deterministic and ordered — the first matching rule wins.

## Clustering

```ruby
clusterer = Iriq::Clusterer.new
clusterer.add("https://foo.com/users/123")
clusterer.add("https://foo.com/users/456")
clusterer.add("https://foo.com/users/789/orders/1")

clusterer.clusters.map(&:shape)
# => ["/users/{integer_id}", "/users/{integer_id}/orders/{integer_id}"]

clusterer.clusters.first.segment_stats
# => [
#      { position: 0, stable: true,  values: { "users" => 2 } },
#      { position: 1, stable: false, values: { "123" => 1, "456" => 1 } },
#    ]

clusterer.explain("https://foo.com/users/999")
# => [
#      { value: "users", type: :literal,    variable: false, stable: true  },
#      { value: "999",   type: :integer_id, variable: true,  stable: false },
#    ]
```

The clusterer combines classifier output with what it has actually observed:
a position the classifier *would* call variable but that is empirically
constant across all members of the cluster will be reported with
`stable: true, variable: false`.

## Object model

| Class                       | Responsibility                                       |
| --------------------------- | ---------------------------------------------------- |
| `Iriq::Parser`              | String → `Identifier`                                |
| `Iriq::Identifier`          | Structured fields + `canonical` reconstruction       |
| `Iriq::SegmentClassifier`   | Single segment → type symbol                         |
| `Iriq::PathShape`           | Segments → `/users/{integer_id}` route shape         |
| `Iriq::Normalizer`          | Identifier → canonical, shape-aware string           |
| `Iriq::Explanation`         | Per-segment `{value, type, variable}` annotations    |
| `Iriq::Cluster`             | One host + shape group, with examples & stats        |
| `Iriq::Clusterer`           | Many identifiers → `Cluster` set + explain          |

## CLI

Installing the gem also installs an `iriq` executable.

```
$ iriq parse https://foo.com/users/123
original:      https://foo.com/users/123
kind:          url
scheme:        https
host:          foo.com
path_segments: ["users", "123"]
canonical:     https://foo.com/users/123

$ iriq normalize foo.com/posts/2024-05-23/hello-world
https://foo.com/posts/{date}/{slug}

$ iriq explain https://foo.com/users/123/orders/456
  literal      users
* integer_id   123
  literal      orders
* integer_id   456

$ iriq classify f47ac10b-58cc-4372-a567-0e02b2c3d479
uuid

$ cat urls.txt | iriq cluster
[2] foo.com  /users/{integer_id}
    https://foo.com/users/1
    https://foo.com/users/2
[1] foo.com  /posts/{slug}/edit
    https://foo.com/posts/abc-123/edit
```

Add `--json` to any command for machine-readable output. `iriq cluster` reads
identifiers (one per line) from a file argument or stdin; lines that fail to
parse are skipped with a warning on stderr.

Exit codes: `0` success, `1` usage error, `2` parse error.

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
## Contributing

Yes please  :)

1. Fork it
1. Create your feature branch (`git checkout -b my-feature`)
1. Ensure the tests pass (`bundle exec rspec`)
1. Commit your changes (`git commit -am 'awesome new feature'`)
1. Push your branch (`git push origin my-feature`)
1. Create a Pull Request
