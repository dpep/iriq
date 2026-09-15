//! # iriq — IRI/URL extraction, normalization, shape clustering
//!
//! iriq finds the *shape* of a URL — the route template behind it. Erase the
//! parts that vary, keep the parts that don't: `/users/123` → `/users/{user_id}`.
//!
//! (An IRI is just a URL — the internationalized superset of URI/URL that also
//! allows non-ASCII characters. If you know URLs, you know IRIs.)
//!
//! ## Quick start
//!
//! ```
//! use iriq::{parse, normalize, Extractor};
//!
//! // Parse + normalize.
//! let iri = parse("https://Foo.com:443/users/123").unwrap();
//! assert_eq!(iri.host, "foo.com");
//! assert_eq!(iri.port, None); // default port stripped
//! assert_eq!(normalize("https://foo.com/users/123").unwrap(),
//!            "https://foo.com/users/{user_id}");
//!
//! // Pull IRIs out of free text.
//! let urls = Extractor::new().extract_strings(
//!     "Visit https://foo.com today, also hit foo.com/users."
//! );
//! assert_eq!(urls.len(), 2);
//! ```
//!
//! ## Streaming clustering with a corpus
//!
//! ```no_run
//! use iriq::Corpus;
//!
//! // Persisted to SQLite (.db / .sqlite / .sqlite3).
//! let mut corpus = Corpus::open("c.db").unwrap();
//! for url in &["https://foo.com/users/1",
//!              "https://foo.com/users/2",
//!              "https://foo.com/users/3"] {
//!     corpus.observe(url).unwrap();
//! }
//! corpus.save("c.db").unwrap();
//! ```
//!
//! Corpora persist to SQLite out of the box (bundled `rusqlite`, WAL,
//! concurrent observers) — no system dependency. That backend lives behind
//! the default-on `sqlite` feature; `default-features = false` drops the
//! bundled C build for consumers who only need parsing, extraction, or
//! normalization, leaving the Memory and JSON backends.
//!
//! See the [project README](https://github.com/dpep/iriq) for the
//! conceptual overview and the CHANGELOG for version history.

// docs.rs builds on nightly with `--cfg docsrs`, where `doc(cfg)` labels the
// SQLite-only items; stable builds never see this.
#![cfg_attr(docsrs, feature(doc_cfg))]

// `color_kind` became unreachable when the surface narrowed; delete it there
// and drop this allow.
#[allow(dead_code)]
mod classifier;
mod cluster;
mod clusterer;
mod corpus;
mod cross_host_shape;
mod errors;
mod event;
mod explanation;
mod extractor;
mod hints;
mod identifier;
mod inflector;
mod normalizer;
mod ordered_map;
mod parser;
mod path_shape;
mod position;
mod position_stats;
mod recognizer_proposal;
mod registrable_domain;
mod shape;
mod storage;
mod storage_json;
mod storage_memory;
#[cfg(feature = "sqlite")]
mod storage_sqlite;
mod synthesized_recognizer;
mod trace;

// The public API. Every name here is a semver promise; everything else is
// crate-private. A type is listed when a public signature or field reaches it.
pub use classifier::{segment_type_from_name, CustomType, FileKind, SegmentType};
pub use cluster::{Cluster, ParamSummary, SegmentPositionStat};
pub use corpus::{Classification, Corpus, CorpusEntry, HostStrategy};
pub use cross_host_shape::CrossHostShape;
pub use errors::{Error, ParseError, Result};
pub use explanation::explain;
pub use extractor::Extractor;
pub use hints::SegmentHint;
pub use identifier::{Identifier, Kind};
pub use inflector::singularize;
pub use normalizer::{normalize, normalize_identifier};
pub use ordered_map::OrderedMap;
pub use parser::parse;
pub use path_shape::path_shape_for;
pub use position::{Position, PositionScope};
pub use position_stats::PositionStats;
pub use recognizer_proposal::{ProposalOptions, RecognizerProposal};
pub use registrable_domain::registrable_domain;
pub use trace::{trace, trace_identifier, TraceResult, TraceRow};

// For the crate's own integration tests only; not part of the API.
#[doc(hidden)]
pub use classifier::{canonical_date, SegmentClassifier};

pub const VERSION: &str = "0.34.0";
