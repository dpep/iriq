use crate::classifier::{
    canonical_currency, canonical_date, display_type, segment_type_from_name, SegmentClassifier,
    SegmentType,
};
use crate::cluster::ParamSummary;
use crate::cluster::{placeholder_for, Cluster};
use crate::clusterer::cluster_key_for_host;
use crate::cross_host_shape::{cross_host_shapes, CrossHostShape};
use crate::errors::{Error, Result};
use crate::event::Event;
use crate::hints::{derive_hints, SegmentHint};
use crate::identifier::Identifier;
use crate::normalizer::{normalize_identifier_with_evidence, render_param, NormalizationEvidence};
use crate::parser::parse;
use crate::position::Position;
use crate::position_stats::DEFAULT_MAX_VALUES_PER_POSITION;
use crate::recognizer_proposal::{propose_recognizers, ProposalOptions, RecognizerProposal};
use crate::registrable_domain::registrable_domain;
use crate::shape::{Shape, ShapeRenderOptions};
use crate::storage::{is_sqlite_path, open_storage, PositionEvidence, Storage};
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
    /// The stored activations `classifier` was built from.
    activations: Vec<serde_json::Value>,
    host_strategy: HostStrategy,
    storage: Box<dyn Storage>,
}

impl Corpus {
    /// An in-memory corpus.
    pub fn new() -> Self {
        Corpus {
            classifier: DEFAULT_CLASSIFIER_ARC.clone(),
            activations: Vec::new(),
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
            activations: Vec::new(),
            host_strategy: HostStrategy::Full,
            storage,
        };
        cp.reapply_activated_recognizers()?;
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

    /// One transaction on SQLite, so a failure part-way leaves none of the
    /// observation behind. Inside `batch` it joins the batch's transaction.
    pub fn observe_iri(&mut self, iri: &Identifier) -> Result<()> {
        self.batch(|c| {
            c.replay(iri)?;
            c.storage.record_observation(&iri.canonical())
        })
    }

    /// Same as `observe` but used during `reinfer` — doesn't record the
    /// IRI again into the source log.
    fn replay(&mut self, iri: &Identifier) -> Result<()> {
        for e in self.events_for_iri(iri) {
            apply_event(e, self.storage.as_mut())?;
        }
        Ok(())
    }

    /// Observe every IRI. On SQLite they commit a turn of about a second at a
    /// time, so other processes writing the corpus get the lock in between; a
    /// failure keeps the turns already committed. Inside `batch` they all join
    /// its transaction.
    pub fn observe_all(&mut self, iris: &[Identifier]) -> Result<()> {
        let mut done = 0;
        while done < iris.len() {
            self.batch(|c| {
                for iri in &iris[done..] {
                    c.observe_iri(iri)?;
                    done += 1;
                    if c.storage.turn_over() {
                        break;
                    }
                }
                Ok(())
            })?;
        }
        Ok(())
    }

    /// Rebuild every view from the observation log. The views change all at
    /// once, keeping what other connections observe meanwhile.
    pub fn reinfer(&mut self) -> Result<()> {
        self.rebuild(None).map(|_| ())
    }

    /// Rebuild every view from the observation log and, given `activation`,
    /// store that recognizer with them: both commit together or not at all.
    /// The replay runs into views only this connection sees, without the
    /// write lock, which it takes just to replay what others observed
    /// meanwhile and install the result. Answers false, changing nothing,
    /// when `activation` is already stored.
    fn rebuild(&mut self, activation: Option<serde_json::Value>) -> Result<bool> {
        let mut planned = self.stored_activations()?;
        if let Some(a) = &activation {
            if self.has_activated(a)? {
                return Ok(false);
            }
            planned.push(a.clone());
        }
        loop {
            let outcome = self
                .build_views(&planned)
                .and_then(|mark| self.install_views(mark, &planned, activation.as_ref()));
            self.storage.discard_rebuild();
            // The rebuild classified with `planned`; storage decides from here.
            let reapplied = self.reapply_activated_recognizers();
            let outcome = outcome?;
            reapplied?;
            match outcome {
                Install::Done(activated) => return Ok(activated),
                Install::Stale(stored) => planned = stored,
            }
        }
    }

    /// Replay the log into a rebuild classified with `activations`, catching
    /// up while each pass replays less than the one before; answers the log
    /// mark replayed through.
    fn build_views(&mut self, activations: &[serde_json::Value]) -> Result<u64> {
        self.use_activations(activations.to_vec());
        self.storage.begin_rebuild()?;
        let mut mark = 0;
        let mut last_pass = usize::MAX;
        loop {
            let (replayed, through) = self.replay_log_since(mark)?;
            mark = through;
            if replayed == 0 || replayed >= last_pass {
                return Ok(mark);
            }
            last_pass = replayed;
        }
    }

    /// Under the write lock, record `activation`, replay the log past `mark`
    /// and install the rebuild — unless the stored activations are no longer
    /// the `planned` set the rebuild classified with.
    fn install_views(
        &mut self,
        mark: u64,
        planned: &[serde_json::Value],
        activation: Option<&serde_json::Value>,
    ) -> Result<Install> {
        self.transaction(|c| {
            if let Some(a) = activation {
                if c.has_activated(a)? {
                    return Ok(Outcome::Rollback(Install::Done(false)));
                }
                c.storage.record_activated_recognizer(a.clone())?;
            }
            let stored = c.stored_activations()?;
            if stored != planned {
                return Ok(Outcome::Rollback(Install::Stale(stored)));
            }
            c.use_activations(stored);
            c.replay_log_since(mark)?;
            c.storage.install_rebuild()?;
            Ok(Outcome::Commit(Install::Done(true)))
        })
    }

    /// Replay the observations logged after `mark`, answering how many and
    /// the mark through them.
    fn replay_log_since(&mut self, mark: u64) -> Result<(usize, u64)> {
        let mut iris = Vec::new();
        let through = self
            .storage
            .each_observed_iri_since(mark, &mut |iri| iris.push(iri.to_string()))?;
        for canonical in &iris {
            self.replay(&parse(canonical)?)?;
        }
        Ok((iris.len(), through))
    }

    pub fn observed_iri_count(&self) -> Result<usize> {
        self.storage.observed_iri_count()
    }

    pub fn propose_recognizers(&self, opts: ProposalOptions) -> Result<Vec<RecognizerProposal>> {
        propose_recognizers(self.storage.as_ref(), opts)
    }

    /// Activate a proposal as a recognizer on this corpus, then reinfer.
    /// Activating one the corpus already holds changes nothing. On SQLite
    /// the activation and its reinfer commit together or not at all.
    pub fn activate_proposal(&mut self, p: &RecognizerProposal) -> Result<()> {
        self.activate(p).map(|_| ())
    }

    /// `activate_proposal`, answering whether `p` was newly activated.
    fn activate(&mut self, p: &RecognizerProposal) -> Result<bool> {
        // The proposal suggests a type name (e.g. "ghp"). Unknown names
        // become dynamic Custom types, matching Ruby's symbol semantics.
        let ty = segment_type_from_name(&p.suggested_type);
        let dump = SynthesizedRecognizer::from_prefix(p.prefix.clone(), ty).dump();
        self.rebuild(Some(dump))
    }

    /// An activation is its prefix and type: specificity never changes what
    /// it classifies, and older binaries stored a different one.
    fn has_activated(&self, dump: &serde_json::Value) -> Result<bool> {
        let mut found = false;
        self.storage.each_activated_recognizer(&mut |stored| {
            found |=
                stored.get("prefix") == dump.get("prefix") && stored.get("type") == dump.get("type")
        })?;
        Ok(found)
    }

    fn stored_activations(&self) -> Result<Vec<serde_json::Value>> {
        let mut stored = Vec::new();
        self.storage
            .each_activated_recognizer(&mut |v| stored.push(v.clone()))?;
        Ok(stored)
    }

    /// Activate every proposal at or above `confidence_threshold`, returning
    /// the proposals newly activated; one the corpus already held is left out.
    pub fn activate_proposals_above(
        &mut self,
        confidence_threshold: f64,
        opts: ProposalOptions,
    ) -> Result<Vec<RecognizerProposal>> {
        let mut activated = Vec::new();
        for p in self.propose_recognizers(opts)? {
            if p.confidence >= confidence_threshold && self.activate(&p)? {
                activated.push(p);
            }
        }
        Ok(activated)
    }

    pub fn activated_recognizer_count(&self) -> Result<usize> {
        self.storage.activated_recognizer_count()
    }

    /// The classifier is a function of the stored activations: the shared
    /// default when there are none, otherwise a private copy holding exactly
    /// the stored set, so a live corpus and its reopened self agree. Rebuilt
    /// only when the set changed, so the classifier keeps its cache.
    fn reapply_activated_recognizers(&mut self) -> Result<()> {
        let stored = self.stored_activations()?;
        self.use_activations(stored);
        Ok(())
    }

    fn use_activations(&mut self, activations: Vec<serde_json::Value>) {
        if activations == self.activations {
            return;
        }
        self.classifier = if activations.is_empty() {
            DEFAULT_CLASSIFIER_ARC.clone()
        } else {
            let classifier = SegmentClassifier::new();
            for r in activations
                .iter()
                .filter_map(SynthesizedRecognizer::from_dump)
            {
                classifier.register_recognizer(Arc::new(r));
            }
            Arc::new(classifier)
        };
        self.activations = activations;
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
                ty: e.ty.clone(),
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

    /// Corpus-informed [`normalize`](crate::normalize). The corpus changes a
    /// shape only at a position or param it has seen at least 5 times; below
    /// that the output is exactly what `normalize` gives.
    ///
    /// Fails when `input` doesn't parse or a corpus read fails.
    pub fn normalize(&self, input: &str) -> Result<String> {
        let iri = parse(input)?;
        self.normalize_identifier(&iri, true)
    }

    /// Corpus-informed [`normalize_identifier`](crate::normalize_identifier).
    /// `hints: false` renders bare type placeholders (`{integer}`), and a slot
    /// only the corpus knows is variable renders `{value}`.
    pub fn normalize_identifier(&self, iri: &Identifier, hints: bool) -> Result<String> {
        normalize_identifier_with_evidence(iri, &self.classifier, hints, self)
    }

    pub fn explain(&self, input: &str) -> Result<Vec<CorpusEntry>> {
        let iri = parse(input)?;
        Ok(self
            .annotate_segments(&iri)?
            .into_iter()
            .map(|a| CorpusEntry {
                hint: a.hint,
                classification: a.classification,
            })
            .collect())
    }

    pub fn host_counts(&self) -> Result<HashMap<String, usize>> {
        self.storage.host_counts()
    }
    pub fn path_length_counts(&self) -> Result<HashMap<usize, usize>> {
        self.storage.path_length_counts()
    }
    pub fn raw_shape_counts(&self) -> Result<HashMap<String, usize>> {
        self.storage.raw_shape_counts()
    }
    pub fn fingerprint_counts(&self) -> Result<HashMap<String, usize>> {
        self.storage.fingerprint_counts()
    }
    pub fn clusters(&self) -> Result<Vec<Cluster>> {
        self.storage.clusters()
    }
    pub fn size(&self) -> Result<usize> {
        self.storage.cluster_size()
    }

    /// Route shapes (path only, host stripped) that recur across at least
    /// `min_hosts` hosts; `0` means the default of 2.
    pub fn cross_host_shapes(&self, min_hosts: usize) -> Result<Vec<CrossHostShape>> {
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
    /// happens. A batch opened inside a batch joins it: only the outermost
    /// commits or rolls back, so a failure `f` swallows keeps its writes.
    /// A batch classifies with every recognizer activated before it began,
    /// including those another process activated.
    pub fn batch<T>(&mut self, f: impl FnOnce(&mut Corpus) -> Result<T>) -> Result<T> {
        self.transaction(|c| f(c).map(Outcome::Commit))
    }

    /// `batch`, where `f` also chooses to roll back without failing.
    fn transaction<T>(&mut self, f: impl FnOnce(&mut Corpus) -> Result<Outcome<T>>) -> Result<T> {
        if self.storage.batch_begin()? {
            if let Err(e) = self.reapply_activated_recognizers() {
                let _ = self.storage.batch_rollback();
                return Err(e);
            }
        }
        // Unwind safety: the rollback below is what restores consistency.
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| f(self))) {
            Ok(Ok(Outcome::Commit(value))) => {
                self.storage.batch_commit()?;
                Ok(value)
            }
            Ok(Ok(Outcome::Rollback(value))) => {
                self.rollback_batch();
                Ok(value)
            }
            // The original failure is the one worth reporting; SQLite may
            // already have ended the transaction, making ROLLBACK itself fail.
            Ok(Err(e)) => {
                self.rollback_batch();
                Err(e)
            }
            Err(panic) => {
                self.rollback_batch();
                std::panic::resume_unwind(panic)
            }
        }
    }

    /// A rollback can take back an activation `f` recorded, so the classifier
    /// is rebuilt from what storage still holds.
    fn rollback_batch(&mut self) {
        let _ = self.storage.batch_rollback();
        let _ = self.reapply_activated_recognizers();
    }

    /// The params of the cluster `input` falls into; empty when that cluster
    /// hasn't been observed.
    pub fn params_for(&self, input: &str) -> Result<Vec<ParamSummary>> {
        let iri = parse(input)?;
        let cluster = self.storage.cluster_for(&self.cluster_key_for_iri(&iri))?;
        Ok(cluster.map(|c| c.param_summary()).unwrap_or_default())
    }

    fn cluster_key_for_iri(&self, iri: &Identifier) -> String {
        let hinted = derive_hints(&iri.path_segments, &self.classifier);
        let shape = Shape::from_entries(hinted).render(ShapeRenderOptions::default());
        cluster_key_for_host(
            iri,
            &self.classifier,
            Some(shape),
            self.effective_host(&iri.host),
        )
        .key
    }

    fn annotate_segments(&self, iri: &Identifier) -> Result<Vec<Annotated>> {
        let hinted = derive_hints(&iri.path_segments, &self.classifier);
        let keying_host = self.effective_host(&iri.host);
        let mut out = Vec::with_capacity(hinted.len());
        let mut prefix = String::new();
        for entry in &hinted {
            // classify_segment answers this whatever the evidence; skip the read.
            let cls = if entry.variable && !stable_variable_type(&entry.ty) {
                Classification::VariableIdentifier
            } else {
                let evidence = self.storage.position_evidence(
                    &Position::path(keying_host.clone(), prefix.clone()),
                    &entry.value,
                )?;
                classify_segment(entry, evidence.as_ref(), &self.classifier)
            };
            out.push(Annotated {
                hint: entry.clone(),
                prefix: prefix.clone(),
                classification: cls,
            });
            prefix.push('/');
            prefix.push_str(&placeholder_for(entry));
        }
        Ok(out)
    }

    fn corpus_token(&self, a: &Annotated, hints: bool) -> String {
        if let Some(canon) = canonical_form(&a.hint.ty, &a.hint.value) {
            return canon;
        }
        match a.classification {
            Classification::VariableIdentifier | Classification::CorpusInferredVariable => {
                placeholder_for_variable(a, hints)
            }
            _ => a.hint.value.clone(),
        }
    }
}

fn placeholder_for_variable(a: &Annotated, hints: bool) -> String {
    if a.hint.variable {
        if hints && !a.hint.hint.is_empty() {
            return format!("{{{}}}", a.hint.hint);
        }
        return format!("{{{}}}", display_type(&a.hint.ty));
    }
    // Corpus-inferred: the classifier said literal, so there's no type to
    // show; with hints, name it after the prefix's last literal segment.
    let last_literal = a
        .prefix
        .split('/')
        .rfind(|part| !part.is_empty() && !part.starts_with('{'));
    match last_literal {
        Some(part) if hints => format!("{{{}}}", crate::inflector::singularize(part)),
        _ => "{value}".to_string(),
    }
}

impl NormalizationEvidence for Corpus {
    type Error = Error;

    fn render_path(&self, iri: &Identifier, _c: &SegmentClassifier, hints: bool) -> Result<String> {
        let tokens: Vec<String> = self
            .annotate_segments(iri)?
            .iter()
            .map(|a| self.corpus_token(a, hints))
            .collect();
        Ok(format!("/{}", tokens.join("/")))
    }
    fn render_query(&self, iri: &Identifier, _c: &SegmentClassifier) -> Result<String> {
        self.render_query_inner(iri)
    }
}

impl Corpus {
    fn render_query_inner(&self, iri: &Identifier) -> Result<String> {
        let mut keys = iri.query_params.keys();
        if keys.is_empty() {
            return Ok(String::new());
        }
        let cluster_key = self.cluster_key_for_iri(iri);
        keys.sort();
        let mut parts = Vec::with_capacity(keys.len());
        for k in keys {
            let v = iri.query_params.get(&k).unwrap_or("");
            parts.push(format!(
                "{}={}",
                k,
                self.render_query_param(&cluster_key, &k, v)?
            ));
        }
        Ok(parts.join("&"))
    }

    // A param the cluster has seen MIN_OBSERVATIONS_FOR_INFERENCE times renders
    // with the cluster's type; below that it renders exactly as mechanical
    // normalize would.
    fn render_query_param(&self, cluster_key: &str, name: &str, value: &str) -> Result<String> {
        let stats = self
            .storage
            .param_stats_for(cluster_key, name)?
            .filter(|s| s.total >= MIN_OBSERVATIONS_FOR_INFERENCE);
        let Some(stats) = stats else {
            return Ok(render_param(name, value, &self.classifier));
        };
        let t = Cluster::param_type_for(name, &stats);
        if let Some(canon) = canonical_form(&t, value) {
            return Ok(canon);
        }
        if self.classifier.variable(&t) {
            return Ok(format!("{{{}}}", display_type(&t)));
        }
        Ok(value.to_string())
    }
}

/// Dates and currencies print in canonical form (ISO date, upper-case code)
/// rather than as a placeholder, as mechanical normalize does.
fn canonical_form(t: &SegmentType, value: &str) -> Option<String> {
    match t {
        SegmentType::Date => canonical_date(value),
        SegmentType::Currency => canonical_currency(value),
        _ => None,
    }
}

enum Outcome<T> {
    Commit(T),
    Rollback(T),
}

/// How installing a rebuild ended.
enum Install {
    /// Installed; false when the activation was already stored.
    Done(bool),
    /// Storage's activations changed since the rebuild began; they now read so.
    Stale(Vec<serde_json::Value>),
}

#[derive(Debug, Clone)]
struct Annotated {
    hint: SegmentHint,
    prefix: String,
    classification: Classification,
}

fn stable_variable_type(t: &SegmentType) -> bool {
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
    stats: Option<&PositionEvidence>,
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
    if entry.variable && !stable_variable_type(&entry.ty) {
        return Classification::VariableIdentifier;
    }

    let total = stats.total;
    let variable_frac = stats.variable_fraction(c);
    let cardinality_frac = (stats.cardinality as f64) / (total as f64);
    let enough_data = total >= MIN_OBSERVATIONS_FOR_INFERENCE;
    let value_frac = stats.value_fraction();

    // A dominant value keeps a stable-variable type (`v1`, `usd`) literal, but
    // only with enough observations to call anything dominant: one sample is
    // always 100%.
    if entry.variable {
        if enough_data && value_frac >= STABLE_LITERAL_THRESHOLD {
            return Classification::StableLiteral;
        }
        return Classification::VariableIdentifier;
    }

    if enough_data && variable_frac >= VARIABLE_DOMINANCE_THRESHOLD {
        if stats.value_count.is_some() {
            return Classification::RareLiteral;
        }
        return Classification::Ambiguous;
    }
    if value_frac >= STABLE_LITERAL_THRESHOLD {
        return Classification::StableLiteral;
    }
    if enough_data && high_cardinality_literal_position(stats, cardinality_frac) {
        if popular_outlier(stats) {
            return Classification::StableLiteral;
        }
        return Classification::CorpusInferredVariable;
    }
    if stats.cardinality == 1 {
        return Classification::StableLiteral;
    }
    if stats.value_count.is_some() {
        return Classification::RareLiteral;
    }
    Classification::Ambiguous
}

fn high_cardinality_literal_position(stats: &PositionEvidence, card_frac: f64) -> bool {
    if card_frac >= LITERAL_UNIQUENESS_THRESHOLD {
        return true;
    }
    card_frac >= LITERAL_UNIQUENESS_MODERATE_THRESHOLD
        && stats.cardinality >= MIN_CARDINALITY_FOR_INFERENCE
}

fn popular_outlier(stats: &PositionEvidence) -> bool {
    let count = stats.value_count.unwrap_or(0);
    if count < POPULAR_MIN_COUNT {
        return false;
    }
    let baseline = 1.0 / (stats.cardinality as f64);
    stats.value_fraction() >= POPULAR_BASELINE_MULTIPLE * baseline
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
        assert_eq!(c.activated_recognizer_count().unwrap(), 1);
    }

    #[cfg(feature = "sqlite")]
    #[test]
    fn a_writer_observes_with_recognizers_another_connection_activated() {
        let dir =
            std::env::temp_dir().join(format!("iriq-corpus-activated-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("c.db");

        let mut writer = Corpus::open(&path).unwrap();
        writer.observe("https://x.com/t/tok_Ab12Cd").unwrap();
        // Another process activating commits the same way a second connection does.
        Corpus::open(&path)
            .unwrap()
            .activate_proposal(&proposal("tok_", "tok"))
            .unwrap();

        writer.observe("https://x.com/t/tok_Ef34Gh").unwrap();
        let shapes: Vec<String> = writer
            .clusters()
            .unwrap()
            .into_iter()
            .map(|c| format!("{} x{}", c.shape, c.count))
            .collect();
        assert_eq!(shapes, ["/t/{tok} x2"]);
    }

    #[cfg(feature = "sqlite")]
    fn scratch_db(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("iriq-corpus-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("c.db")
    }

    #[cfg(feature = "sqlite")]
    fn cluster_counts(c: &Corpus) -> Vec<(String, usize)> {
        let mut counts: Vec<_> = c
            .clusters()
            .unwrap()
            .into_iter()
            .map(|c| (c.shape, c.count))
            .collect();
        counts.sort();
        counts
    }

    // The rebuild itself runs apart from the lock, where other connections'
    // writes land.
    #[cfg(feature = "sqlite")]
    #[test]
    fn a_rebuild_keeps_what_another_connection_observes_while_it_replays() {
        let path = scratch_db("rebuild-observed");
        let mut corpus = Corpus::open(&path).unwrap();
        for i in 0..3 {
            corpus.observe(&format!("https://x.com/t/{i}")).unwrap();
        }
        let planned = corpus.stored_activations().unwrap();
        let mark = corpus.build_views(&planned).unwrap();

        Corpus::open(&path)
            .unwrap()
            .observe("https://x.com/t/99")
            .unwrap();
        let installed = corpus.install_views(mark, &planned, None).unwrap();
        corpus.storage.discard_rebuild();

        assert!(matches!(installed, Install::Done(true)));
        let live = cluster_counts(&corpus);
        assert_eq!(live, [("/t/{t_id}".to_string(), 4)]);
        corpus.reinfer().unwrap();
        assert_eq!(cluster_counts(&corpus), live);
    }

    #[cfg(feature = "sqlite")]
    #[test]
    fn a_rebuild_starts_over_when_another_connection_activates_while_it_replays() {
        let path = scratch_db("rebuild-activated");
        let mut corpus = Corpus::open(&path).unwrap();
        for tok in ["tok_Ab12Cd", "tok_Ef34Gh"] {
            corpus.observe(&format!("https://x.com/t/{tok}")).unwrap();
        }
        let planned = corpus.stored_activations().unwrap();
        let mark = corpus.build_views(&planned).unwrap();

        Corpus::open(&path)
            .unwrap()
            .activate_proposal(&proposal("tok_", "tok"))
            .unwrap();
        let installed = corpus.install_views(mark, &planned, None).unwrap();
        corpus.storage.discard_rebuild();
        corpus.reapply_activated_recognizers().unwrap();

        assert!(matches!(installed, Install::Stale(ref stored) if stored.len() == 1));
        assert_eq!(cluster_counts(&corpus), [("/t/{tok}".to_string(), 2)]);
        corpus.reinfer().unwrap();
        assert_eq!(cluster_counts(&corpus), [("/t/{tok}".to_string(), 2)]);
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
