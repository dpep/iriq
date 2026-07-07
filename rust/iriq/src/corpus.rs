use crate::classifier::{canonical_date, segment_type_from_str, SegmentClassifier, SegmentType};
use crate::cluster::ParamSummary;
use crate::cluster::{placeholder_for, Cluster};
use crate::clusterer::cluster_key_for_host;
use crate::errors::ParseError;
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
use crate::storage::{open_storage, Storage};
use crate::storage_memory::MemoryStorage;
use crate::synthesized_recognizer::SynthesizedRecognizer;
use std::collections::HashMap;
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
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

pub const VARIABLE_DOMINANCE_THRESHOLD: f64 = 0.8;
pub const LITERAL_UNIQUENESS_THRESHOLD: f64 = 0.8;
pub const LITERAL_UNIQUENESS_MODERATE_THRESHOLD: f64 = 0.5;
pub const MIN_CARDINALITY_FOR_INFERENCE: usize = 20;
pub const MIN_OBSERVATIONS_FOR_INFERENCE: usize = 5;
pub const STABLE_LITERAL_THRESHOLD: f64 = 0.5;
pub const POPULAR_MIN_COUNT: usize = 5;
pub const POPULAR_BASELINE_MULTIPLE: f64 = 3.0;

#[derive(Debug, Clone)]
pub struct CorpusEntry {
    pub hint: SegmentHint,
    pub classification: Classification,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum HostStrategy {
    #[default]
    Full,
    Registrable,
    None,
}

pub struct Corpus {
    /// Classifier — `Arc` so a Corpus can swap to its own per-corpus
    /// classifier without affecting `DEFAULT_CLASSIFIER` (Activate path).
    pub classifier: Arc<SegmentClassifier>,
    pub host_strategy: HostStrategy,
    storage: Box<dyn Storage>,
}

impl Corpus {
    pub fn new() -> Self {
        Self::new_with_classifier(
            DEFAULT_CLASSIFIER_ARC.clone(),
            DEFAULT_MAX_VALUES_PER_POSITION,
        )
    }

    pub fn new_with_classifier(c: Arc<SegmentClassifier>, max_values: usize) -> Self {
        Corpus {
            classifier: c,
            host_strategy: HostStrategy::Full,
            storage: Box::new(MemoryStorage::new(max_values)),
        }
    }

    pub fn open(path: &str) -> Result<Self, std::io::Error> {
        let storage = open_storage(path, DEFAULT_MAX_VALUES_PER_POSITION)?;
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

    pub fn storage(&self) -> &dyn Storage {
        self.storage.as_ref()
    }

    pub fn storage_mut(&mut self) -> &mut dyn Storage {
        self.storage.as_mut()
    }

    pub fn effective_host(&self, host: &str) -> String {
        match self.host_strategy {
            HostStrategy::Registrable => registrable_domain(host),
            HostStrategy::None => String::new(),
            HostStrategy::Full => host.to_string(),
        }
    }

    pub fn observe(&mut self, input: &str) -> Result<(), ParseError> {
        let iri = parse(input)?;
        self.observe_iri(&iri);
        Ok(())
    }

    pub fn observe_iri(&mut self, iri: &Identifier) {
        let events = self.events_for_iri(iri);
        for e in events {
            apply_event(e, self.storage.as_mut());
        }
        self.storage.record_observation(&iri.canonical());
    }

    /// Same as `observe` but used during `reinfer` — doesn't record the
    /// IRI again into the source log.
    fn replay(&mut self, iri: &Identifier) {
        let events = self.events_for_iri(iri);
        for e in events {
            apply_event(e, self.storage.as_mut());
        }
    }

    pub fn reinfer(&mut self) -> Result<(), ParseError> {
        let mut iris = Vec::new();
        self.storage
            .each_observed_iri(&mut |c| iris.push(c.to_string()));
        self.storage.clear_materialized_views();
        for canonical in iris {
            let iri = parse(&canonical)?;
            self.replay(&iri);
        }
        Ok(())
    }

    pub fn observed_iri_count(&self) -> usize {
        self.storage.observed_iri_count()
    }

    pub fn propose_recognizers(&self, opts: ProposalOptions) -> Vec<RecognizerProposal> {
        propose_recognizers(self.storage.as_ref(), opts)
    }

    pub fn activate_proposal(
        &mut self,
        p: &RecognizerProposal,
    ) -> Result<SynthesizedRecognizer, ParseError> {
        // Synthesized recognizer needs an explicit type. The proposal
        // currently suggests a type name (e.g. "ghp"); we don't have
        // dynamic registration of new types, so we fall back to
        // SegmentType::OpaqueId for now and let the prefix-based recognizer
        // claim those values with higher specificity.
        let ty = segment_type_from_str(&p.suggested_type).unwrap_or(SegmentType::OpaqueId);
        let r = SynthesizedRecognizer::from_prefix(p.prefix.clone(), ty);
        self.ensure_per_corpus_classifier();
        self.classifier
            .register_recognizer(Arc::new(SynthesizedRecognizer {
                prefix: r.prefix.clone(),
                ty: r.ty,
                specificity: r.specificity,
            }));
        self.storage.record_activated_recognizer(r.dump());
        self.reinfer()?;
        Ok(r)
    }

    pub fn activate_proposals_above(
        &mut self,
        confidence_threshold: f64,
        opts: ProposalOptions,
    ) -> Result<Vec<SynthesizedRecognizer>, ParseError> {
        let proposals = self.propose_recognizers(opts);
        let mut activated = Vec::new();
        for p in proposals {
            if p.confidence < confidence_threshold {
                continue;
            }
            activated.push(self.activate_proposal(&p)?);
        }
        Ok(activated)
    }

    pub fn activated_recognizer_count(&self) -> usize {
        self.storage.activated_recognizer_count()
    }

    fn ensure_per_corpus_classifier(&mut self) {
        if Arc::ptr_eq(&self.classifier, &DEFAULT_CLASSIFIER_ARC) {
            self.classifier = Arc::new(SegmentClassifier::new());
        }
    }

    fn reapply_activated_recognizers(&mut self) {
        if self.storage.activated_recognizer_count() == 0 {
            return;
        }
        self.ensure_per_corpus_classifier();
        let mut recos = Vec::new();
        self.storage.each_activated_recognizer(&mut |v| {
            if let Some(r) = SynthesizedRecognizer::from_dump(v) {
                recos.push(r);
            }
        });
        for r in recos {
            self.classifier.register_recognizer(Arc::new(r));
        }
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

    pub fn normalize(&self, input: &str) -> Result<String, ParseError> {
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
    pub fn max_values_per_position(&self) -> usize {
        self.storage.max_values()
    }

    pub fn stats_for(&self, host: &str, prefix: &str) -> Option<PositionStats> {
        self.storage
            .position_stats_for(&Position::path(host, prefix))
    }

    pub fn save(&mut self, path: &str) -> std::io::Result<()> {
        let backend = self.storage.path().unwrap_or_default();
        if path.is_empty() || path == backend {
            self.storage.flush()
        } else {
            self.storage.save_to(path)
        }
    }

    pub fn close(&mut self) -> std::io::Result<()> {
        self.storage.close()
    }

    /// Wrap many observations in a single backend transaction.
    pub fn batch<F: FnOnce(&mut Corpus)>(&mut self, fn_: F) -> std::io::Result<()> {
        self.storage.batch_begin()?;
        fn_(self);
        self.storage.batch_commit()
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
            return format!("{{{}}}", a.hint.ty.as_str());
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
            return format!("{{{}}}", t.as_str());
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

fn apply_event(e: Event, s: &mut dyn Storage) {
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
