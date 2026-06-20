// Rust port of iriq (Go module github.com/dpep/iriq).
// Ruby is the reference; Go mirrors Ruby; Rust mirrors Go.

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
#[cfg(feature = "sqlite")]
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

pub const VERSION: &str = "0.29.1";
pub const HAS_SQLITE: bool = cfg!(feature = "sqlite");
