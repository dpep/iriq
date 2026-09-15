// The crate docs are the README, so its samples compile and run as doctests.
#![doc = include_str!("../README.md")]
// docs.rs builds on nightly with `--cfg docsrs`, where `doc(cfg)` labels the
// SQLite-only items; stable builds never see this.
#![cfg_attr(docsrs, feature(doc_cfg))]

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

pub const VERSION: &str = "0.35.0";
