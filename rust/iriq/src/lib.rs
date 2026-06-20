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
pub mod position_stats;
pub mod cluster;
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

pub const VERSION: &str = "0.29.1";
