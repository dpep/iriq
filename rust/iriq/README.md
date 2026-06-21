# iriq — IRI/URL extraction, normalization, shape clustering

**iriq finds the *shape* of a URL** — the route template hiding behind it.
Erase the parts that vary, keep the parts that don't: `/users/123` and
`/users/999` are both `/users/{user_id}`. Point it at a pile of messy URLs and
it collapses them into a small set of stable, deterministic templates.

(An **IRI** is just a URL — the internationalized superset of URI/URL that also
allows non-ASCII characters. If you know URLs, you know IRIs. The name is *IRI
Query*: iriq queries an IRI for its structure.)

```toml
[dependencies]
iriq = "0.29"
```

Corpora persist to SQLite (bundled `rusqlite`, WAL, concurrent observers) — no
system dependency, nothing to set up.

## What it does

```rust
use iriq::{parse, normalize, Extractor, trace};

// Parse and normalize a single URL.
let iri = parse("https://Foo.com:443/users/123")?;
assert_eq!(iri.host, "foo.com");
assert_eq!(iri.port, 0);            // default port dropped
assert_eq!(normalize("https://foo.com/users/123")?,
           "https://foo.com/users/{user_id}");

// Pull URLs out of free text.
let urls = Extractor::new().extract_strings(
    "Visit https://foo.com today, also hit foo.com/users."
);
assert_eq!(urls.len(), 2);

// Annotated trace (what the CLI shows under `-e`).
let tr = trace("https://shop.com/pricing/usd?currency=eur")?;
assert_eq!(tr.normalized, "https://shop.com/pricing/USD?currency=EUR");
# Ok::<(), Box<dyn std::error::Error>>(())
```

Streaming clustering with a persistent corpus:

```rust,no_run
use iriq::Corpus;

// Persisted to SQLite (.db / .sqlite / .sqlite3).
let mut corpus = Corpus::open("c.db")?;
for url in &["https://foo.com/users/1",
             "https://foo.com/users/2",
             "https://foo.com/users/3"] {
    corpus.observe(url)?;
}
corpus.save("c.db")?;
# Ok::<(), Box<dyn std::error::Error>>(())
```

## What's covered

- **Segment classification** — ~25 typed shapes (UUID, ISO date, file, email,
  IPv4/6, color, coordinate, country, base64, JWT, MIME, phone, and more).
- **Shape normalization** — route templates with canonical date and currency
  rendering, and RESTful hints (`{user_id}` from `/users/123`).
- **Trace** — per-segment annotations for any URL (`trace`).
- **Corpus** — streaming shape clustering, param-type inference, and learning:
  `--stats`, `--reinfer`, `--propose-recognizers`, `--cross-host-shapes`.

## License

[MIT](https://github.com/dpep/iriq). See the [crate docs](https://docs.rs/iriq)
for the full API and the [project README](https://github.com/dpep/iriq) for the
conceptual overview.
