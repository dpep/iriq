# iriq

**iriq finds the *shape* of a URL**: the route template behind it. Erase the
parts that vary, keep the parts that don't, and `/users/123` and `/users/999`
both become `/users/{user_id}`. Point it at a pile of messy URLs and it
collapses them into a small set of stable, deterministic templates.

An IRI is a URL that's allowed to contain non-ASCII characters; if you know
URLs, you know IRIs. The name is *IRI Query*.

This crate is both the library and the `iriq` command-line tool. This page
covers the library; the [project README](https://github.com/dpep/iriq#readme)
covers the CLI.

```sh
cargo add iriq          # library
cargo install iriq      # CLI
```

Requires Rust 1.85 or newer.

## Parse, normalize, extract

The pure functions need no setup and fail only with `ParseError`.

```rust
use iriq::{normalize, parse, trace, Extractor};

fn main() -> Result<(), iriq::ParseError> {
    let iri = parse("https://Foo.com:443/users/123?tab=posts")?;
    assert_eq!(iri.host, "foo.com");
    assert_eq!(iri.port, None); // the scheme's default port is dropped
    assert_eq!(iri.path_segments, ["users", "123"]);
    assert_eq!(iri.canonical(), "https://foo.com/users/123?tab=posts");

    // The shape: variable parts become placeholders, and the fragment goes.
    assert_eq!(
        normalize("https://foo.com/users/123#bio")?,
        "https://foo.com/users/{user_id}"
    );

    // Pull URLs out of free text, including scheme-less ones like foo.com/users.
    let urls = Extractor::new().extract_strings("Visit https://foo.com today, or foo.com/users.");
    assert_eq!(urls.len(), 2);

    // Why each part rendered the way it did (the CLI's `-e`).
    let t = trace("https://shop.com/pricing/usd?currency=eur")?;
    assert_eq!(t.normalized, "https://shop.com/pricing/USD?currency=EUR");
    Ok(())
}
```

## Learn from a stream with a corpus

A `Corpus` observes URLs and learns from what it sees: which slots vary, which
query params are enums, which values are HTTP statuses. It groups what it has
seen into clusters, one per route.

```rust
use iriq::Corpus;

fn main() -> iriq::Result<()> {
    let mut corpus = Corpus::new(); // in memory
    for n in 1..=20 {
        corpus.observe(&format!("https://api.foo.com/orders/{n}?status=open"))?;
        corpus.observe(&format!("https://api.foo.com/orders/{n}?status=closed"))?;
    }

    let clusters = corpus.clusters()?;
    assert_eq!(clusters.len(), 1);
    let orders = &clusters[0];
    assert_eq!((orders.host.as_str(), orders.shape.as_str()), ("api.foo.com", "/orders/{order_id}"));
    assert_eq!(orders.count, 40);

    // One URL can't show that ?status is an enum; forty can.
    let status = &orders.param_summary()[0];
    assert_eq!((status.name.as_str(), status.ty.as_str()), ("status", "enum"));
    println!("{} {} conf {:.2}", status.name, status.ty, status.confidence);

    assert_eq!(
        corpus.normalize("https://api.foo.com/orders/99?status=open")?,
        "https://api.foo.com/orders/{order_id}?status={enum}"
    );
    Ok(())
}
```

The corpus changes a shape only at a position or param it has seen at least 5
times. Until then, `corpus.normalize` returns exactly what `normalize` does.

## Persist a corpus

`Corpus::open(path)` picks the backend by extension: `.db`, `.sqlite` and
`.sqlite3` are SQLite; anything else is JSON. Wrap a run of observations in
`batch` to make it one transaction: it commits when the closure returns `Ok`
and rolls back on `Err` or a panic.

```rust,no_run
use std::io::BufRead;
use iriq::{parse, Corpus};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let lines = std::io::stdin().lock().lines().collect::<Result<Vec<_>, _>>()?;

    let mut corpus = Corpus::open("routes.db")?;
    corpus.batch(|c| {
        for line in &lines {
            // Skip input that isn't a URL; a storage failure still aborts the batch.
            if let Ok(iri) = parse(line) {
                c.observe_iri(&iri)?;
            }
        }
        Ok(())
    })?;

    corpus.save("routes.db")?; // its own path: flush in place (a .json corpus is written here)
    corpus.save("routes-export.json")?; // any other path: a JSON export
    Ok(())
}
```

`save` exports only JSON: saving to another `.db` path returns
`Error::Unsupported` and writes nothing.

### Sharing a corpus between processes

- **SQLite** is the one to share. Many processes can observe into one `.db` at
  once; each writer waits up to 30 seconds for another's transaction to finish.
- **JSON** is single-writer. The file is read at `open` and written at `save`,
  so when two processes save the same file, the last one wins.
- **Activated recognizers.** When another process activates a recognizer (the
  CLI's `--activate-above`), a long-lived `Corpus` picks it up at the start of
  its next `batch`, and `observe` counts as one. Reads outside a batch
  (`normalize`, `clusters`, …) keep classifying with what the corpus had
  before. Reopen the corpus, or read inside `batch` (which on SQLite takes the
  write lock), to see the new ones.

## Errors

Every `Corpus` operation returns `iriq::Result<T>`, whose error is
`iriq::Error`. Its `Display` names the corpus that failed; the underlying cause
is its `source()`. `Error` is `#[non_exhaustive]`, so a `match` needs a `_` arm.

```rust
use std::error::Error as _;
use iriq::{Corpus, Error};

fn main() {
    // Input that doesn't parse.
    let err = Corpus::new().observe("http://").unwrap_err();
    assert!(matches!(err, Error::Parse(_)));

    // A corpus file that can't be opened.
    let path = std::env::temp_dir().join("iriq-no-such-dir/c.json");
    let err = Corpus::open(&path).unwrap_err();
    match &err {
        Error::Io { path, .. } => assert!(path.ends_with("c.json")),
        _ => unreachable!("a missing directory is an I/O error"),
    }
    eprintln!("iriq: {err}: {}", err.source().unwrap());
}
```

`Error::Corrupt` is a file that isn't a usable corpus (a JSON file that isn't
an iriq corpus). `Error::Unsupported` is one this build can't use: a SQLite
corpus from a newer iriq, or any `.db` in a build without the `sqlite` feature.
`Error::Sqlite` (only with that feature) is SQLite refusing an operation.

## Features

`sqlite` (on by default) bundles SQLite through `rusqlite`, so there's no
system library to install. If you only need parsing, extraction or
normalization, turn it off to skip compiling the C library:

```sh
cargo add iriq --no-default-features
```

In-memory and JSON corpora still work; opening a `.db` returns
`Error::Unsupported`.

## More

- [API docs](https://docs.rs/iriq)
- [Project README](https://github.com/dpep/iriq#readme): the CLI, and how
  classification and the corpus work
- [Changelog](https://github.com/dpep/iriq/blob/main/CHANGELOG.md)
- License: [MIT](https://github.com/dpep/iriq/blob/main/LICENSE.txt)
