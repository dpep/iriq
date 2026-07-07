use crate::classifier::{
    file_kind, param_name_hint, FileKind, SegmentClassifier, SegmentType, DEFAULT_CLASSIFIER,
};
use crate::hints::SegmentHint;
use crate::identifier::Identifier;
use crate::position_stats::{PositionStats, DEFAULT_MAX_VALUES_PER_POSITION};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

pub const MAX_CLUSTER_EXAMPLES: usize = 10;
pub const DATE_CONFIDENCE_THRESHOLD: f64 = 0.8;
pub const NUMBER_CONFIDENCE_THRESHOLD: f64 = 0.8;
pub const NUMBER_SUBTYPE_THRESHOLD: f64 = 0.8;

// Param classification is a confidence ladder: constant → string → enum. A
// single-valued param is a constant (rendered as-is); one that varies but
// isn't a trustworthy enum is SegmentType::String (a generic placeholder); a
// bounded, well-supported value set is SegmentType::Enum.
//
// An enum is promoted when there are enough samples to trust the bound
// (ENUM_MIN_OBSERVATIONS), the *established* values — those seen at least
// ENUM_MIN_VALUE_COUNT times — number between ENUM_MIN_MEMBERS and
// ENUM_MAX_CARDINALITY, and cover nearly all observations (ENUM_MIN_COVERAGE).
// Rare one-off values are stragglers, not disqualifiers, so a single brand-new
// value can't knock an established enum down (the observe-before-normalize case).
pub const ENUM_MIN_OBSERVATIONS: usize = 20;
pub const ENUM_MAX_CARDINALITY: usize = 10;
pub const ENUM_MIN_VALUE_COUNT: usize = 3;
pub const ENUM_MIN_COVERAGE: f64 = 0.9;
// An enum is a bounded *set*: a single repeated value is a constant, not an
// enum, so it takes at least two established members to qualify.
pub const ENUM_MIN_MEMBERS: usize = 2;

// A literal-valued param that has taken on at least this many distinct values
// varies, so it's SegmentType::String rather than a fixed constant.
pub const STRING_MIN_DISTINCT: usize = 2;

// confidence = total / (total + K): a monotone curve that is 0.5 at K
// observations and asymptotes to 1.0. The type names our guess; this number
// says how much evidence backs it.
pub const CONFIDENCE_SMOOTHING: usize = 15;

pub const YEAR_RANGE_MIN: f64 = 1900.0;
pub const YEAR_RANGE_MAX: f64 = 2100.0;
pub const YEAR_MIN_OBSERVATIONS: usize = 5;
pub const YEAR_MIN_DISTINCT: usize = 2;
pub const YEAR_MAX_DISTINCT: usize = 150;

pub const HTTP_STATUS_RANGE_MIN: f64 = 100.0;
pub const HTTP_STATUS_RANGE_MAX: f64 = 599.0;
pub const HTTP_STATUS_MIN_OBSERVATIONS: usize = 5;
pub const HTTP_STATUS_MIN_DISTINCT: usize = 2;
pub const HTTP_STATUS_MAX_DISTINCT: usize = 30;

#[derive(Debug, Clone)]
pub struct SegmentPositionStat {
    pub position: usize,
    pub stable: bool,
    pub values: HashMap<String, usize>,
}

#[derive(Debug, Clone)]
pub struct Cluster {
    pub key: String,
    pub host: String,
    pub scheme: String,
    pub shape: String,
    pub examples: Vec<Arc<Identifier>>,
    pub count: usize,
    pub segment_counts: Vec<HashMap<String, usize>>,
    pub param_stats: HashMap<String, PositionStats>,
    pub max_values: usize,
    pub example_keys: HashSet<String>,
}

impl Cluster {
    pub fn new(
        key: String,
        host: String,
        scheme: String,
        shape: String,
        max_values: usize,
    ) -> Self {
        let cap = if max_values == 0 {
            DEFAULT_MAX_VALUES_PER_POSITION
        } else {
            max_values
        };
        Cluster {
            key,
            host,
            scheme,
            shape,
            examples: Vec::new(),
            count: 0,
            segment_counts: Vec::new(),
            param_stats: HashMap::new(),
            max_values: cap,
            example_keys: HashSet::new(),
        }
    }

    pub fn add(&mut self, iri: &Identifier) {
        self.add_with(iri, &DEFAULT_CLASSIFIER)
    }

    pub fn add_with(&mut self, iri: &Identifier, classifier: &SegmentClassifier) {
        self.count += 1;
        if self.examples.len() < MAX_CLUSTER_EXAMPLES {
            let canon = iri.canonical();
            if self.example_keys.insert(canon) {
                self.examples.push(Arc::new(iri.clone()));
            }
        }
        for (i, seg) in iri.path_segments.iter().enumerate() {
            while self.segment_counts.len() <= i {
                self.segment_counts.push(HashMap::new());
            }
            *self.segment_counts[i].entry(seg.clone()).or_insert(0) += 1;
        }
        for (name, v) in iri.query_params.iter() {
            let stats = self
                .param_stats
                .entry(name.to_string())
                .or_insert_with(|| PositionStats::new(self.max_values));
            stats.observe(v, classifier.classify(v));
        }
    }

    pub fn register_example_key(&mut self, canon: String) {
        self.example_keys.insert(canon);
    }

    pub fn segment_stats(&self) -> Vec<SegmentPositionStat> {
        self.segment_counts
            .iter()
            .enumerate()
            .map(|(i, counts)| SegmentPositionStat {
                position: i,
                stable: counts.len() == 1,
                values: counts.clone(),
            })
            .collect()
    }

    pub fn param_summary(&self) -> Vec<ParamSummary> {
        if self.param_stats.is_empty() {
            return Vec::new();
        }
        let mut rows: Vec<ParamSummary> = self
            .param_stats
            .iter()
            .map(|(name, stats)| {
                let presence = if self.count > 0 {
                    (stats.total as f64) / (self.count as f64)
                } else {
                    0.0
                };
                let ty = self.param_type(name);
                let mut row = ParamSummary {
                    name: name.clone(),
                    count: stats.total,
                    ty,
                    confidence: param_confidence(stats),
                    cardinality: stats.cardinality(),
                    presence,
                    values: Vec::new(),
                    numeric_count: 0,
                    min: 0.0,
                    max: 0.0,
                    avg: 0.0,
                    value_distribution: HashMap::new(),
                    subtype_distribution: HashMap::new(),
                    kind_distribution: HashMap::new(),
                };
                if row.ty == SegmentType::Enum {
                    row.values = enum_values(stats);
                }
                if row.ty == SegmentType::Boolean || row.ty == SegmentType::Enum {
                    row.value_distribution = value_distribution(stats);
                }
                if row.ty == SegmentType::Number {
                    row.subtype_distribution =
                        subtype_distribution(stats, &[SegmentType::Integer, SegmentType::Float]);
                }
                if row.ty == SegmentType::File {
                    row.kind_distribution = file_kind_distribution(stats);
                }
                if stats.numeric_count > 0 {
                    row.numeric_count = stats.numeric_count;
                    row.min = stats.numeric_min;
                    row.max = stats.numeric_max;
                    row.avg = stats.numeric_avg();
                }
                row
            })
            .collect();
        sort_param_summary(&mut rows);
        rows
    }

    pub fn param_type(&self, name: &str) -> SegmentType {
        let stats = match self.param_stats.get(name) {
            Some(s) if s.total > 0 => s,
            _ => return SegmentType::Literal,
        };
        let t = stats.dominant_type();

        if is_year_position(t, stats) {
            return SegmentType::Year;
        }
        if is_http_status_position(t, stats) {
            return SegmentType::HttpStatus;
        }

        if is_enum(stats) && t != SegmentType::Boolean {
            return SegmentType::Enum;
        }

        if t == SegmentType::Date {
            let date_frac = (*stats.type_counts.get(&SegmentType::Date).unwrap_or(&0) as f64)
                / (stats.total as f64);
            if date_frac >= DATE_CONFIDENCE_THRESHOLD {
                return t;
            }
            if let Some(alt) = dominant_excluding(stats, SegmentType::Date) {
                return alt;
            }
            return SegmentType::Literal;
        }

        if t == SegmentType::Integer || t == SegmentType::Float {
            let int_frac = (*stats.type_counts.get(&SegmentType::Integer).unwrap_or(&0) as f64)
                / (stats.total as f64);
            let float_frac = (*stats.type_counts.get(&SegmentType::Float).unwrap_or(&0) as f64)
                / (stats.total as f64);
            if int_frac < NUMBER_SUBTYPE_THRESHOLD
                && float_frac < NUMBER_SUBTYPE_THRESHOLD
                && (int_frac + float_frac) >= NUMBER_CONFIDENCE_THRESHOLD
            {
                return SegmentType::Number;
            }
        }

        if let Some(hint) = param_name_hint(name, t) {
            return hint;
        }

        // String rung — a literal-valued param that has taken on more than one
        // distinct value varies, so it's a placeholder, not a fixed constant.
        // Below the enum bar (checked above), so we claim only "free-form text".
        if t == SegmentType::Literal && stats.cardinality() >= STRING_MIN_DISTINCT {
            return SegmentType::String;
        }
        t
    }
}

#[derive(Debug, Clone)]
pub struct ParamSummary {
    pub name: String,
    pub count: usize,
    pub ty: SegmentType,
    pub confidence: f64,
    pub cardinality: usize,
    pub presence: f64,
    pub values: Vec<String>,
    pub numeric_count: usize,
    pub min: f64,
    pub max: f64,
    pub avg: f64,
    pub value_distribution: HashMap<String, f64>,
    pub subtype_distribution: HashMap<SegmentType, f64>,
    pub kind_distribution: HashMap<FileKind, f64>,
}

fn round_frac(f: f64) -> f64 {
    (f * 10000.0).round() / 10000.0
}

pub fn value_distribution(stats: &PositionStats) -> HashMap<String, f64> {
    if stats.total == 0 {
        return HashMap::new();
    }
    stats
        .value_counts
        .iter()
        .map(|(v, n)| (v.clone(), round_frac((*n as f64) / (stats.total as f64))))
        .collect()
}

pub fn subtype_distribution(
    stats: &PositionStats,
    subtypes: &[SegmentType],
) -> HashMap<SegmentType, f64> {
    if stats.total == 0 {
        return HashMap::new();
    }
    let mut out = HashMap::new();
    for &t in subtypes {
        let n = *stats.type_counts.get(&t).unwrap_or(&0);
        if n > 0 {
            out.insert(t, round_frac((n as f64) / (stats.total as f64)));
        }
    }
    out
}

pub fn file_kind_distribution(stats: &PositionStats) -> HashMap<FileKind, f64> {
    if stats.value_counts.is_empty() {
        return HashMap::new();
    }
    let total: usize = stats.value_counts.values().sum();
    if total == 0 {
        return HashMap::new();
    }
    let mut counts: HashMap<Option<FileKind>, usize> = HashMap::new();
    for (v, n) in &stats.value_counts {
        let k = file_kind(v);
        *counts.entry(k).or_insert(0) += *n;
    }
    let mut out = HashMap::new();
    for (k, n) in counts {
        // Unknown values are bucketed separately in Ruby under :unknown;
        // here we filter to known kinds. (Phase 1 omitted this nuance; phase 2 keeps it.)
        if let Some(kind) = k {
            out.insert(kind, round_frac((n as f64) / (total as f64)));
        }
    }
    out
}

// The enum's member values — the established ones (seen enough to be real),
// ordered by descending count with a lex tie-break. Stragglers are excluded so
// the advertised set is what the corpus is actually confident about.
pub fn enum_values(stats: &PositionStats) -> Vec<String> {
    let mut keys: Vec<String> = stats
        .value_counts
        .iter()
        .filter(|(_, &n)| n >= ENUM_MIN_VALUE_COUNT)
        .map(|(k, _)| k.clone())
        .collect();
    keys.sort_by(|a, b| {
        let na = stats.value_counts[a];
        let nb = stats.value_counts[b];
        nb.cmp(&na).then(a.cmp(b))
    });
    keys
}

// Built around the *established* members (values seen at least
// ENUM_MIN_VALUE_COUNT times) so a stray one-off value is a straggler, not a
// disqualifier.
pub fn is_enum(stats: &PositionStats) -> bool {
    if stats.total < ENUM_MIN_OBSERVATIONS {
        return false;
    }
    let mut established = 0usize; // established members
    let mut covered = 0usize; // observations they account for
    for &n in stats.value_counts.values() {
        if n >= ENUM_MIN_VALUE_COUNT {
            established += 1;
            covered += n;
        }
    }
    if !(ENUM_MIN_MEMBERS..=ENUM_MAX_CARDINALITY).contains(&established) {
        return false;
    }
    (covered as f64) / (stats.total as f64) >= ENUM_MIN_COVERAGE
}

// How much evidence backs the assigned type: monotone in observation count,
// 0.5 at CONFIDENCE_SMOOTHING, asymptoting to 1.0. Rounded to two decimals to
// match the Ruby/Go output.
pub fn param_confidence(stats: &PositionStats) -> f64 {
    if stats.total == 0 {
        return 0.0;
    }
    let c = (stats.total as f64) / ((stats.total + CONFIDENCE_SMOOTHING) as f64);
    (c * 100.0).round() / 100.0
}

pub fn is_year_position(t: SegmentType, stats: &PositionStats) -> bool {
    if t != SegmentType::Integer || stats.numeric_count == 0 {
        return false;
    }
    let card = stats.cardinality();
    if !(YEAR_MIN_DISTINCT..=YEAR_MAX_DISTINCT).contains(&card) {
        return false;
    }
    if stats.total < YEAR_MIN_OBSERVATIONS {
        return false;
    }
    stats.numeric_min >= YEAR_RANGE_MIN
        && stats.numeric_min <= YEAR_RANGE_MAX
        && stats.numeric_max >= YEAR_RANGE_MIN
        && stats.numeric_max <= YEAR_RANGE_MAX
}

pub fn is_http_status_position(t: SegmentType, stats: &PositionStats) -> bool {
    if t != SegmentType::Integer || stats.numeric_count == 0 {
        return false;
    }
    let card = stats.cardinality();
    if !(HTTP_STATUS_MIN_DISTINCT..=HTTP_STATUS_MAX_DISTINCT).contains(&card) {
        return false;
    }
    if stats.total < HTTP_STATUS_MIN_OBSERVATIONS {
        return false;
    }
    stats.numeric_min >= HTTP_STATUS_RANGE_MIN
        && stats.numeric_min <= HTTP_STATUS_RANGE_MAX
        && stats.numeric_max >= HTTP_STATUS_RANGE_MIN
        && stats.numeric_max <= HTTP_STATUS_RANGE_MAX
}

pub fn dominant_excluding(stats: &PositionStats, skip: SegmentType) -> Option<SegmentType> {
    let mut best: Option<(SegmentType, usize)> = None;
    for (&t, &n) in &stats.type_counts {
        if t == skip {
            continue;
        }
        best = match best {
            None => Some((t, n)),
            Some((bt, bn)) => {
                if n > bn || (n == bn && t.as_str() < bt.as_str()) {
                    Some((t, n))
                } else {
                    Some((bt, bn))
                }
            }
        };
    }
    best.map(|(t, _)| t)
}

fn sort_param_summary(rows: &mut [ParamSummary]) {
    rows.sort_by(|a, b| b.count.cmp(&a.count).then(a.name.cmp(&b.name)));
}

// Conveniences used by Cluster / Corpus when deriving keys.
pub fn placeholder_for(e: &SegmentHint) -> String {
    if !e.variable {
        return e.value.clone();
    }
    if !e.hint.is_empty() {
        return format!("{{{}}}", e.hint);
    }
    format!("{{{}}}", e.ty.as_str())
}
