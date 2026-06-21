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
//! assert_eq!(iri.port, 0);
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
//! Corpora persist to SQLite out of the box (bundled [`rusqlite`], WAL,
//! concurrent observers) — no system dependency.
//!
//! See the [project README](https://github.com/dpep/iriq) for the
//! conceptual overview and the CHANGELOG for version history.

pub mod errors;
pub mod identifier;
pub mod ordered_map;
pub mod parser;
pub mod registrable_domain;
pub mod classifier;
pub mod inflector;
pub mod hints;
pub mod shape;
pub mod path_shape;
pub mod normalizer;
pub mod extractor;
pub mod explanation;
pub mod trace;
pub mod position;
pub mod position_stats;
pub mod cluster;
pub mod clusterer;
pub mod event;
pub mod observation;
pub mod storage;
pub mod storage_memory;
pub mod storage_json;
pub mod storage_sqlite;
pub mod synthesized_recognizer;
pub mod recognizer_proposal;
pub mod cross_host_shape;
pub mod corpus;

pub use errors::ParseError;
pub use identifier::{Identifier, Kind};
pub use ordered_map::OrderedMap;
pub use parser::parse;
pub use classifier::{
    canonical_currency, canonical_date, color_kind, display_type, file_kind,
    param_name_hint, FileKind, SegmentClassifier, SegmentType, DEFAULT_CLASSIFIER,
};
pub use registrable_domain::registrable_domain;
pub use normalizer::{
    normalize, normalize_identifier, normalize_identifier_with_evidence, NormalizationEvidence,
    NullEvidence,
};
pub use hints::{derive_hints, derive_hints_default, SegmentHint};
pub use shape::{Shape, ShapeRenderOptions};
pub use path_shape::{path_shape_for, PathShape};
pub use inflector::singularize;
pub use extractor::Extractor;
pub use explanation::{explain, explain_identifier};
pub use trace::{trace, trace_identifier, TraceResult, TraceRow};
pub use position::{Position, PositionScope};
pub use position_stats::{PositionStats, DEFAULT_MAX_VALUES_PER_POSITION};
pub use cluster::{Cluster, ParamSummary, SegmentPositionStat};
pub use clusterer::{cluster_key_for, cluster_key_for_host, ClusterKey, Clusterer, ExplainEntry};
pub use corpus::{Classification, Corpus, CorpusEntry, HostStrategy};
pub use storage::{open_storage, Storage};
pub use cross_host_shape::CrossHostShape;
pub use recognizer_proposal::{ProposalOptions, RecognizerProposal};
pub use synthesized_recognizer::SynthesizedRecognizer;

pub const VERSION: &str = "0.30.0";
