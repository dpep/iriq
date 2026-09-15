use crate::classifier::{
    canonical_date, display_type, segment_type_from_name, SegmentClassifier, SegmentType,
};
use crate::cluster::ParamSummary;
use crate::cluster::{placeholder_for, Cluster};
use crate::clusterer::cluster_key_for_host;
use crate::cross_host_shape::{cross_host_shapes, CrossHostShape};
use crate::errors::{Error, ParseError, Result};
use crate::event::Event;
use crate::hints::{derive_hints, SegmentHint};
use crate::identifier::Identifier;
use crate::normalizer::{normalize_identifier_with_evidence, NormalizationEvidence};
use crate::parser::parse;
use crate::position::Position;
use crate::position_stats::{PositionStats, DEFAULT_MAX_VALUES_PER_POSITION};
use crate::recognizer_proposal::{propose_recognizers, ProposalOptions, RecognizerProposal};
use crate::registrable_domain::registrable_domain;
use crate::shape::{Shape, ShapeRenderOptions};
use crate::storage::{is_sqlite_path, open_storage, Storage};
use crate::storage_memory::MemoryStorage;
use crate::synthesized_recognizer::SynthesizedRecognizer;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum Classification {
    StableLiteral,
    VariableIdentifier,
    RareLiteral,
    Ambiguous,
    CorpusInferredVariable,
}

impl Classification {
    pub fn as_str(&self) -> &'static str {
        match self {
            Classification::StableLiteral => "stable_literal",
            Classification::VariableIdentifier => "variable_identifier",
            Classification::RareLiteral => "rare_literal",
            Classification::Ambiguous => "ambiguous",
            Classification::CorpusInferredVariable => "corpus_inferred_variable",
        }
    }
}

const VARIABLE_DOMINANCE_THRESHOLD: f64 = 0.8;
const LITERAL_UNIQUENESS_THRESHOLD: f64 = 0.8;
const LITERAL_UNIQUENESS_MODERATE_THRESHOLD: f64 = 0.5;
const MIN_CARDINALITY_FOR_INFERENCE: usize = 20;
const MIN_OBSERVATIONS_FOR_INFERENCE: usize = 5;
const STABLE_LITERAL_THRESHOLD: f64 = 0.5;
const POPULAR_MIN_COUNT: usize = 5;
const POPULAR_BASELINE_MULTIPLE: f64 = 3.0;

#[derive(Debug, Clone)]
#[non_exhaustive]
pub struct CorpusEntry {
    pub hint: SegmentHint,
    pub classification: Classification,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[non_exhaustive]
pub enum HostStrategy {
    #[default]
    Full,
    Registrable,
    None,
}

pub struct Corpus {
    /// The shared default classifier until a recognizer is activated, then a
    /// private copy (see `reapply_activated_recognizers`).
    classifier: Arc<SegmentClassifier>,
    host_strategy: HostStrategy,
    storage: Box<dyn Storage>,
}

impl Corpus {
    /// An in-memory corpus.
    pub fn new() -> Self {
        Corpus {
            classifier: DEFAULT_CLASSIFIER_ARC.clone(),
            host_strategy: HostStrategy::Full,
            storage: Box::new(MemoryStorage::new(DEFAULT_MAX_VALUES_PER_POSITION)),
        }
    }

    /// Open, or start, the corpus at `path`. The extension picks the backend:
    /// `.db` / `.sqlite` / `.sqlite3` is SQLite, anything else JSON.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let storage = open_storage(path.as_ref(), DEFAULT_MAX_VALUES_PER_POSITION)?;
        let mut cp = Corpus {
            classifier: DEFAULT_CLASSIFIER_ARC.clone(),
            host_strategy: HostStrategy::Full,
            storage,
        };
        cp.reapply_activated_recognizers();
        Ok(cp)
    }

    pub fn set_host_strategy(&mut self, s: HostStrategy) {
        self.host_strategy = s;
    }

    fn effective_host(&self, host: &str) -> String {
        match self.host_strategy {
            HostStrategy::Registrable => registrable_domain(host),
            HostStrategy::None => String::new(),
            HostStrategy::Full => host.to_string(),
        }
    }

    pub fn observe(&mut self, input: &str) -> Result<()> {
        let iri = parse(input)?;
        self.observe_iri(&iri)
    }

    pub fn observe_iri(&mut self, iri: &Identifier) -> Result<()> {
        self.replay(iri)?;
        self.storage.record_observation(&iri.canonical())
    }

    /// Same as `observe` but used during `reinfer` — doesn't record the
    /// IRI again into the source log.
    fn replay(&mut self, iri: &Identifier) -> Result<()> {
        for e in self.events_for_iri(iri) {
            apply_event(e, self.storage.as_mut())?;
        }
        Ok(())
    }

    pub fn reinfer(&mut self) -> Result<()> {
        let mut iris = Vec::new();
        self.storage
            .each_observed_iri(&mut |c| iris.push(c.to_string()));
        self.storage.clear_materialized_views()?;
        for canonical in iris {
            let iri = parse(&canonical)?;
            self.replay(&iri)?;
        }
        Ok(())
    }

    pub fn observed_iri_count(&self) -> usize {
        self.storage.observed_iri_count()
    }

    pub fn propose_recognizers(&self, opts: ProposalOptions) -> Vec<RecognizerProposal> {
        propose_recognizers(self.storage.as_ref(), opts)
    }

    /// Activate a proposal as a recognizer on this corpus, then reinfer.
    /// Activating one the corpus already holds changes nothing.
    pub fn activate_proposal(&mut self, p: &RecognizerProposal) -> Result<()> {
        // The proposal suggests a type name (e.g. "ghp"). Unknown names
        // become dynamic Custom types, matching Ruby's symbol semantics.
        let ty = segment_type_from_name(&p.suggested_type);
        let dump = SynthesizedRecognizer::from_prefix(p.prefix.clone(), ty).dump();
        if self.has_activated(&dump) {
            return Ok(());
        }
        self.storage.record_activated_recognizer(dump)?;
        self.reapply_activated_recognizers();
        self.reinfer()
    }

    fn has_activated(&self, dump: &serde_json::Value) -> bool {
        let mut found = false;
        self.storage
            .each_activated_recognizer(&mut |stored| found |= stored == dump);
        found
    }

    /// Activate every proposal at or above `confidence_threshold`, returning
    /// the proposals activated.
    pub fn activate_proposals_above(
        &mut self,
        confidence_threshold: f64,
        opts: ProposalOptions,
    ) -> Result<Vec<RecognizerProposal>> {
        let mut activated = Vec::new();
        for p in self.propose_recognizers(opts) {
            if p.confidence < confidence_threshold {
                continue;
            }
            self.activate_proposal(&p)?;
            activated.push(p);
        }
        Ok(activated)
    }

    pub fn activated_recognizer_count(&self) -> usize {
        self.storage.activated_recognizer_count()
    }

    /// The classifier is a function of the stored activations: the shared
    /// default when there are none, otherwise a private copy holding exactly
    /// the stored set, so a live corpus and its reopened self agree.
    fn reapply_activated_recognizers(&mut self) {
        let mut recognizers = Vec::new();
        self.storage.each_activated_recognizer(&mut |v| {
            if let Some(r) = SynthesizedRecognizer::from_dump(v) {
                recognizers.push(r);
            }
        });
        if recognizers.is_empty() {
            return;
        }
        let classifier = SegmentClassifier::new();
        for r in recognizers {
            classifier.register_recognizer(Arc::new(r));
        }
        self.classifier = Arc::new(classifier);
    }

    fn events_for_iri(&self, iri: &Identifier) -> Vec<Event> {
        let hinted = derive_hints(&iri.path_segments, &self.classifier);
        let raw_shape = Shape::from_entries(hinted.clone()).render(ShapeRenderOptions {
            hints_off: true,
            ..Default::default()
        });
        let hinted_shape =
            Shape::from_entries(hinted.clone()).render(ShapeRenderOptions::default());
        let keying_host = self.effective_host(&iri.host);

        let mut events = vec![
            Event::HostSeen {
                host: keying_host.clone(),
            },
            Event::PathLengthSeen {
                length: iri.path_segments.len(),
            },
            Event::RawShapeSeen { shape: raw_shape },
            Event::FingerprintSeen {
                shape: hinted_shape.clone(),
            },
        ];

        let mut prefix = String::new();
        for e in &hinted {
            events.push(Event::PositionSeen {
                position: Position::path(keying_host.clone(), prefix.clone()),
                value: e.value.clone(),
                ty: e.ty,
            });
            prefix.push('/');
            prefix.push_str(&placeholder_for(e));
        }

        let k = cluster_key_for_host(
            iri,
            &self.classifier,
            Some(hinted_shape.clone()),
            keying_host,
        );
        events.push(Event::ClusterAddition {
            key: k.key,
            host: k.host,
            scheme: k.scheme,
            shape: k.shape,
            iri: Box::new(iri.clone()),
        });
        events
    }

    pub fn normalize(&self, input: &str) -> std::result::Result<String, ParseError> {
        let iri = parse(input)?;
        Ok(self.normalize_identifier(&iri))
    }

    pub fn normalize_identifier(&self, iri: &Identifier) -> String {
        let ev: &dyn NormalizationEvidence = self;
        normalize_identifier_with_evidence(iri, &self.classifier, true, ev)
    }

    pub fn explain(&self, input: &str) -> Vec<CorpusEntry> {
        let iri = match parse(input) {
            Ok(i) => i,
            Err(_) => return Vec::new(),
        };
        self.annotate_segments(&iri)
            .into_iter()
            .map(|a| CorpusEntry {
                hint: a.hint,
                classification: a.classification,
            })
            .collect()
    }

    pub fn host_counts(&self) -> HashMap<String, usize> {
        self.storage.host_counts()
    }
    pub fn path_length_counts(&self) -> HashMap<usize, usize> {
        self.storage.path_length_counts()
    }
    pub fn raw_shape_counts(&self) -> HashMap<String, usize> {
        self.storage.raw_shape_counts()
    }
    pub fn fingerprint_counts(&self) -> HashMap<String, usize> {
        self.storage.fingerprint_counts()
    }
    pub fn clusters(&self) -> Vec<Cluster> {
        self.storage.clusters()
    }
    pub fn size(&self) -> usize {
        self.storage.cluster_size()
    }

    /// Route shapes (path only, host stripped) that recur across at least
    /// `min_hosts` hosts; `0` means the default of 2.
    pub fn cross_host_shapes(&self, min_hosts: usize) -> Vec<CrossHostShape> {
        cross_host_shapes(self, min_hosts)
    }

    /// Persist the corpus. Saving to the corpus's own file (however it is
    /// spelled) flushes it in place; any other path receives a JSON export,
    /// so a SQLite extension there is refused rather than written unopenable.
    pub fn save(&mut self, path: impl AsRef<Path>) -> Result<()> {
        let path = path.as_ref();
        let is_live = self
            .storage
            .path()
            .is_some_and(|live| resolve(live) == resolve(path));
        if path.as_os_str().is_empty() || is_live {
            return self.storage.flush();
        }
        if is_sqlite_path(path) {
            return Err(Error::unsupported(
                path,
                "a corpus exports as JSON; use a .json path",
            ));
        }
        self.storage.save_to(path)
    }

    pub fn close(&mut self) -> Result<()> {
        self.storage.close()
    }

    /// Run `f` as one backend transaction. On SQLite it commits when `f`
    /// returns `Ok`, and rolls back when `f` returns `Err` or panics (the
    /// panic then continues); Memory and JSON corpora apply each write as it
    /// happens.
    pub fn batch<T>(&mut self, f: impl FnOnce(&mut Corpus) -> Result<T>) -> Result<T> {
        self.storage.batch_begin()?;
        // Unwind safety: the rollback below is what restores consistency.
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| f(self))) {
            Ok(Ok(value)) => {
                self.storage.batch_commit()?;
                Ok(value)
            }
            // The original failure is the one worth reporting; SQLite may
            // already have ended the transaction, making ROLLBACK itself fail.
            Ok(Err(e)) => {
                let _ = self.storage.batch_rollback();
                Err(e)
            }
            Err(panic) => {
                let _ = self.storage.batch_rollback();
                std::panic::resume_unwind(panic)
            }
        }
    }

    pub fn params_for(&self, input: &str) -> Vec<ParamSummary> {
        let Ok(iri) = parse(input) else {
            return Vec::new();
        };
        let cluster = self.cluster_for_iri(&iri);
        cluster.map(|c| c.param_summary()).unwrap_or_default()
    }

    fn cluster_for_iri(&self, iri: &Identifier) -> Option<Cluster> {
        let hinted = derive_hints(&iri.path_segments, &self.classifier);
        let shape = Shape::from_entries(hinted).render(ShapeRenderOptions::default());
        let k = cluster_key_for_host(
            iri,
            &self.classifier,
            Some(shape),
            self.effective_host(&iri.host),
        );
        self.storage.cluster_for(&k.key)
    }

    fn annotate_segments(&self, iri: &Identifier) -> Vec<Annotated> {
        let hinted = derive_hints(&iri.path_segments, &self.classifier);
        let keying_host = self.effective_host(&iri.host);
        let mut out = Vec::with_capacity(hinted.len());
        let mut prefix = String::new();
        for entry in &hinted {
            let stats = self
                .storage
                .position_stats_for(&Position::path(keying_host.clone(), prefix.clone()));
            let cls = classify_segment(entry, stats.as_ref(), &self.classifier);
            out.push(Annotated {
                hint: entry.clone(),
                prefix: prefix.clone(),
                classification: cls,
            });
            prefix.push('/');
            prefix.push_str(&placeholder_for(entry));
        }
        out
    }

    fn corpus_token(&self, a: &Annotated) -> String {
        match a.classification {
            Classification::VariableIdentifier | Classification::CorpusInferredVariable => {
                self.placeholder_for_variable(a)
            }
            _ => a.hint.value.clone(),
        }
    }

    fn placeholder_for_variable(&self, a: &Annotated) -> String {
        if a.hint.ty == SegmentType::Date {
            if let Some(canon) = canonical_date(&a.hint.value) {
                return canon;
            }
        }
        if a.hint.variable {
            if !a.hint.hint.is_empty() {
                return format!("{{{}}}", a.hint.hint);
            }
            return format!("{{{}}}", display_type(a.hint.ty));
        }
        let mut last_literal = String::new();
        for part in a.prefix.split('/') {
            if part.is_empty() || part.starts_with('{') {
                continue;
            }
            last_literal = part.to_string();
        }
        if !last_literal.is_empty() {
            return format!("{{{}}}", crate::inflector::singularize(&last_literal));
        }
        "{value}".to_string()
    }
}

impl NormalizationEvidence for Corpus {
    fn render_path(&self, iri: &Identifier, _c: &SegmentClassifier, _hints: bool) -> String {
        let entries = self.annotate_segments(iri);
        let tokens: Vec<String> = entries.iter().map(|a| self.corpus_token(a)).collect();
        format!("/{}", tokens.join("/"))
    }
    fn render_query(&self, iri: &Identifier, _c: &SegmentClassifier) -> String {
        self.render_query_inner(iri)
    }
}

impl Corpus {
    fn render_query_inner(&self, iri: &Identifier) -> String {
        let cluster = self.cluster_for_iri(iri);
        let mut keys = iri.query_params.keys();
        keys.sort();
        let mut parts = Vec::with_capacity(keys.len());
        for k in keys {
            let v = iri.query_params.get(&k).unwrap_or("").to_string();
            let t = self.inferred_param_type(cluster.as_ref(), &k, &v);
            parts.push(format!("{}={}", k, self.render_param_value(&v, t)));
        }
        parts.join("&")
    }

    fn inferred_param_type(
        &self,
        cluster: Option<&Cluster>,
        name: &str,
        value: &str,
    ) -> SegmentType {
        if let Some(c) = cluster {
            if let Some(s) = c.param_stats.get(name) {
                if s.total >= MIN_OBSERVATIONS_FOR_INFERENCE {
                    return c.param_type(name);
                }
            }
        }
        self.classifier.classify(value)
    }

    fn render_param_value(&self, value: &str, t: SegmentType) -> String {
        if t == SegmentType::Date {
            if let Some(canon) = canonical_date(value) {
                return canon;
            }
        }
        if self.classifier.variable(t) {
            return format!("{{{}}}", display_type(t));
        }
        value.to_string()
    }
}

#[derive(Debug, Clone)]
struct Annotated {
    hint: SegmentHint,
    prefix: String,
    classification: Classification,
}

fn stable_variable_type(t: SegmentType) -> bool {
    matches!(
        t,
        SegmentType::Version
            | SegmentType::Locale
            | SegmentType::Currency
            | SegmentType::Boolean
            | SegmentType::Slug
            | SegmentType::OpaqueId
    )
}

fn classify_segment(
    entry: &SegmentHint,
    stats: Option<&PositionStats>,
    c: &SegmentClassifier,
) -> Classification {
    let Some(stats) = stats else {
        if entry.variable {
            return Classification::VariableIdentifier;
        }
        return Classification::Ambiguous;
    };
    if stats.total == 0 {
        if entry.variable {
            return Classification::VariableIdentifier;
        }
        return Classification::Ambiguous;
    }
    if entry.variable && !stable_variable_type(entry.ty) {
        return Classification::VariableIdentifier;
    }

    let value = &entry.value;
    let total = stats.total;
    let variable_frac = stats.variable_fraction(c);
    let cardinality_frac = (stats.cardinality() as f64) / (total as f64);
    let enough_data = total >= MIN_OBSERVATIONS_FOR_INFERENCE;
    let value_frac = stats.value_fraction(value);

    if entry.variable {
        if value_frac >= STABLE_LITERAL_THRESHOLD {
            return Classification::StableLiteral;
        }
        return Classification::VariableIdentifier;
    }

    if enough_data && variable_frac >= VARIABLE_DOMINANCE_THRESHOLD {
        if stats.value_counts.contains_key(value) {
            return Classification::RareLiteral;
        }
        return Classification::Ambiguous;
    }
    if value_frac >= STABLE_LITERAL_THRESHOLD {
        return Classification::StableLiteral;
    }
    if enough_data && high_cardinality_literal_position(stats, cardinality_frac) {
        if popular_outlier(stats, value) {
            return Classification::StableLiteral;
        }
        return Classification::CorpusInferredVariable;
    }
    if stats.cardinality() == 1 {
        return Classification::StableLiteral;
    }
    if stats.value_counts.contains_key(value) {
        return Classification::RareLiteral;
    }
    Classification::Ambiguous
}

fn high_cardinality_literal_position(stats: &PositionStats, card_frac: f64) -> bool {
    if card_frac >= LITERAL_UNIQUENESS_THRESHOLD {
        return true;
    }
    card_frac >= LITERAL_UNIQUENESS_MODERATE_THRESHOLD
        && stats.cardinality() >= MIN_CARDINALITY_FOR_INFERENCE
}

fn popular_outlier(stats: &PositionStats, value: &str) -> bool {
    let count = *stats.value_counts.get(value).unwrap_or(&0);
    if count < POPULAR_MIN_COUNT {
        return false;
    }
    let baseline = 1.0 / (stats.cardinality() as f64);
    stats.value_fraction(value) >= POPULAR_BASELINE_MULTIPLE * baseline
}

/// The real location a path names, so two spellings of one file compare
/// equal. A file that doesn't exist yet resolves through its directory.
fn resolve(path: &Path) -> PathBuf {
    if let Ok(real) = std::fs::canonicalize(path) {
        return real;
    }
    let (Some(dir), Some(name)) = (path.parent(), path.file_name()) else {
        return path.to_path_buf();
    };
    let dir = if dir.as_os_str().is_empty() {
        Path::new(".")
    } else {
        dir
    };
    std::fs::canonicalize(dir)
        .map(|d| d.join(name))
        .unwrap_or_else(|_| path.to_path_buf())
}

fn apply_event(e: Event, s: &mut dyn Storage) -> Result<()> {
    match e {
        Event::HostSeen { host } => s.increment_host(&host),
        Event::PathLengthSeen { length } => s.increment_path_length(length),
        Event::RawShapeSeen { shape } => s.increment_raw_shape(&shape),
        Event::FingerprintSeen { shape } => s.increment_fingerprint(&shape),
        Event::PositionSeen {
            position,
            value,
            ty,
        } => s.observe_position(&position, &value, ty),
        Event::ClusterAddition {
            key,
            host,
            scheme,
            shape,
            iri,
        } => s.add_to_cluster(&key, &host, &scheme, &shape, &iri),
    }
}

use once_cell::sync::Lazy;
static DEFAULT_CLASSIFIER_ARC: Lazy<Arc<SegmentClassifier>> =
    Lazy::new(|| Arc::new(SegmentClassifier::new()));

impl Default for Corpus {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Debug for Corpus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Corpus")
            .field("path", &self.storage.path())
            .field("host_strategy", &self.host_strategy)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn proposal(prefix: &str, ty: &str) -> RecognizerProposal {
        RecognizerProposal {
            prefix: prefix.into(),
            suggested_type: ty.into(),
            positions: vec![],
            hosts: vec![],
            coverage: 1.0,
            confidence: 1.0,
            observation_count: 0,
            sample_values: vec![],
            strategy: "manual".into(),
        }
    }

    #[test]
    fn reactivating_a_recognizer_changes_nothing() {
        let mut c = Corpus::new();
        c.observe("https://x.com/t/tok_abc1").unwrap();
        c.activate_proposal(&proposal("tok_", "tok")).unwrap();
        let live = c.classifier.recognizer_count();
        for _ in 0..3 {
            c.activate_proposal(&proposal("tok_", "tok")).unwrap();
        }
        assert_eq!(c.classifier.recognizer_count(), live);
        assert_eq!(c.activated_recognizer_count(), 1);
    }

    #[test]
    fn activation_stays_inside_its_corpus() {
        let url = "https://x.com/items/tok_Ab12Cd";
        let untouched = Corpus::new();
        let corpus_before = untouched.normalize(url).unwrap();
        let free_before = crate::normalize(url).unwrap();

        let mut activated = Corpus::new();
        activated
            .activate_proposal(&proposal("tok_", "tok"))
            .unwrap();
        assert_ne!(activated.normalize(url).unwrap(), corpus_before);

        assert_eq!(untouched.normalize(url).unwrap(), corpus_before);
        assert_eq!(Corpus::new().normalize(url).unwrap(), corpus_before);
        assert_eq!(crate::normalize(url).unwrap(), free_before);
    }
}
