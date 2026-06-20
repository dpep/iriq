# iriq — IRI extraction, normalization, clustering

A Rust port of the [iriq](https://github.com/dpep/iriq) Ruby gem and Go
module. Same behavior across all three runtimes — enforced by golden
JSON fixtures and a CLI parity harness in CI.

```toml
[dependencies]
iriq = "0.29"
```

For SQLite-backed corpora (the on-disk store with concurrent observers):

```toml
[dependencies]
iriq = { version = "0.29", features = ["sqlite"] }
```

## What it does

```rust
use iriq::{parse, normalize, Extractor, Corpus, trace};

// Parse and normalize a single URL.
let iri = parse("https://Foo.com:443/users/123")?;
assert_eq!(iri.host, "foo.com");
assert_eq!(iri.port, 0);            // default port dropped
assert_eq!(normalize("https://foo.com/users/123")?,
           "https://foo.com/users/{user_id}");

// Pull IRIs out of free text.
let urls = Extractor::new().extract_strings(
    "Visit https://foo.com today, also hit foo.com/users."
);
assert_eq!(urls.len(), 2);

// Annotated trace (what the CLI shows under `-e`).
let tr = trace("https://shop.com/pricing/usd?currency=eur")?;
assert_eq!(tr.normalized, "https://shop.com/pricing/USD?currency=EUR");

// Streaming clustering with a persistent corpus.
let mut corpus = Corpus::open("c.db")?;       // .db/.sqlite/.sqlite3 → SQLite
for url in &["https://foo.com/users/1",
             "https://foo.com/users/2",
             "https://foo.com/users/3"] {
    corpus.observe(url)?;
}
corpus.save("c.db")?;
# Ok::<(), Box<dyn std::error::Error>>(())
```

See the [crate docs](https://docs.rs/iriq) for the full API and the
[main project README](https://github.com/dpep/iriq) for the conceptual
overview shared with the Ruby + Go siblings.

## Features

| Feature   | What it does                                                       |
| --------- | ------------------------------------------------------------------ |
| (default) | Memory + JSON corpus backends. Pure Rust, no system deps.          |
| `sqlite`  | Adds the SQLite corpus backend via bundled `rusqlite`. Concurrent writers, incremental UPSERTs. |

## Parity guarantees

This crate is byte-identical to the Ruby gem + Go module on:

- All segment classification decisions (~25 typed shapes — UUID, ISO
  date, file, email, IPv4/6, color, coordinate, country, base64, JWT,
  MIME, phone, etc.).
- `Iriq::Normalizer.normalize` / `iriq.Normalize` outputs, including
  hint suppression for semantic types and canonical date / currency
  rendering.
- `Iriq::Trace.for` / `iriq.Trace` JSON structure for `-e` output.
- Corpus shape clustering, param-type inference, `--stats` /
  `--reinfer` / `--propose-recognizers` / `--cross-host-shapes`
  output.
- Cross-runtime SQLite corpus files (schema v4 is shared — a `.db`
  created by the Go CLI opens cleanly under the Rust CLI and vice
  versa).

Anywhere they diverge is a bug — file an issue with the diff.

## License

MIT, same as the Ruby gem and Go module.
