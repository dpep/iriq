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
# => "https://foo.com/users/{user_id}"

Iriq.explain("https://foo.com/users/123/orders/456")
# => [
#      { value: "users",  type: :literal,    variable: false, hint: nil        },
#      { value: "123",    type: :integer_id, variable: true,  hint: "user_id"  },
#      { value: "orders", type: :literal,    variable: false, hint: nil        },
#      { value: "456",    type: :integer_id, variable: true,  hint: "order_id" },
#    ]
```

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

## CLI

Installing the gem also installs an `iriq` executable. The default action is
a combined summary; section flags trim it.

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

# explain
  literal      literal      users
* integer_id   user_id      456

$ iriq -n https://foo.com/users/123
https://foo.com/users/{user_id}

$ iriq -ne foo.com/posts/2024-05-23/hello-world
# normalize
https://foo.com/posts/{post_id}/{slug}

# explain
  literal      literal      posts
* date         post_id      2024-05-23
* slug         slug         hello-world

$ cat urls.txt | iriq cluster
[2] foo.com  /users/{user_id}
    https://foo.com/users/1
    https://foo.com/users/2
[1] foo.com  /posts/{post_id}/edit
    https://foo.com/posts/abc-123/edit
```

Flags:

| Flag             | Effect                                                  |
| ---------------- | ------------------------------------------------------- |
| `-p, --parse`    | Show parsed fields                                      |
| `-n, --normalize`| Show the shape-normalized form                          |
| `-e, --explain`  | Show per-segment annotations                            |
| `-j, --json`     | Emit JSON; with one section flag, just that payload     |
| `--no-hints`     | Use `{integer_id}` etc. instead of `{user_id}`          |
| `-V, --version`  | Print version                                           |

`iriq cluster` is the lone subcommand (it takes many inputs, not one). It
reads identifiers one per line from a file argument or stdin; lines that
fail to parse are skipped with a warning on stderr.

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
