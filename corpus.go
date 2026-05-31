package iriq

import (
	"sort"
	"strings"
)

// Classification labels mirror the symbols Ruby's Corpus#explain emits.
type Classification string

const (
	ClassStableLiteral          Classification = "stable_literal"
	ClassVariableIdentifier     Classification = "variable_identifier"
	ClassRareLiteral            Classification = "rare_literal"
	ClassAmbiguous              Classification = "ambiguous"
	ClassCorpusInferredVariable Classification = "corpus_inferred_variable"
)

const (
	VariableDominanceThreshold         = 0.8
	LiteralUniquenessThreshold         = 0.8
	LiteralUniquenessModerateThreshold = 0.5
	MinCardinalityForInference         = 20
	MinObservationsForInference        = 5
	StableLiteralThreshold             = 0.5
	PopularMinCount                    = 5
	PopularBaselineMultiple            = 3
)

// CorpusEntry is a SegmentHint plus the corpus's classification verdict.
// Mirrors the symbol-keyed hash returned by Ruby's Corpus#explain.
type CorpusEntry struct {
	SegmentHint
	Classification Classification
}

// Corpus is a streaming observer over a (potentially unbounded) corpus of
// IRIs, maintaining rolling aggregates and per-(host, prefix) frequency
// stats so classification can improve as more data flows in.
//
// State lives in a Storage backend — MemoryStorage by default, JSONStorage
// or SqliteStorage when opened against a file via OpenCorpus.
type Corpus struct {
	Classifier    *SegmentClassifier
	HostStrategy  HostStrategy
	storage       Storage
}

// HostStrategy controls how iri.Host is keyed into clusters / position
// stats / host_counts. The original host always lives on the parsed
// Identifier and surfaces in Normalize output; this only affects how the
// corpus groups observations.
type HostStrategy int

const (
	// HostStrategyFull keys by the original host (today's default).
	HostStrategyFull HostStrategy = iota
	// HostStrategyRegistrable collapses subdomains via the inline-PSL
	// heuristic — api.foo.com + app.foo.com → foo.com.
	HostStrategyRegistrable
	// HostStrategyNone ignores host entirely so clusters group across all
	// hosts by shape alone.
	HostStrategyNone
)

// NewCorpus returns a Corpus backed by an in-memory store using default
// settings.
func NewCorpus() *Corpus { return NewCorpusWith(DefaultClassifier, DefaultMaxValuesPerPosition) }

// NewCorpusWith returns an in-memory Corpus with explicit classifier and cap.
func NewCorpusWith(c *SegmentClassifier, maxValues int) *Corpus {
	if c == nil {
		c = DefaultClassifier
	}
	return &Corpus{Classifier: c, storage: NewMemoryStorageWith(maxValues, c)}
}

// NewCorpusWithStorage wraps any Storage in a Corpus.
func NewCorpusWithStorage(c *SegmentClassifier, s Storage) *Corpus {
	if c == nil {
		c = DefaultClassifier
	}
	return &Corpus{Classifier: c, storage: s}
}

// SetHostStrategy lets callers swap the host-keying mode after construction.
// Has no effect on observations already recorded — only future Observe calls
// (and any Normalize / ParamsFor lookups) see the new strategy.
func (cp *Corpus) SetHostStrategy(s HostStrategy) { cp.HostStrategy = s }

// effectiveHost applies HostStrategy to iri.Host. The original host stays
// on the parsed Identifier for Normalize output; this is only used for
// clustering / stats keys.
func (cp *Corpus) effectiveHost(host string) string {
	switch cp.HostStrategy {
	case HostStrategyRegistrable:
		return RegistrableDomain(host)
	case HostStrategyNone:
		return ""
	default:
		return host
	}
}

// OpenCorpus opens a corpus against path; file extension picks the backend
// (.db/.sqlite/.sqlite3 = SQLite, anything else = JSON).
func OpenCorpus(path string) (*Corpus, error) {
	s, err := OpenStorageWith(path, DefaultMaxValuesPerPosition, DefaultClassifier)
	if err != nil {
		return nil, err
	}
	cp := NewCorpusWithStorage(DefaultClassifier, s)
	cp.reapplyActivatedRecognizers()
	return cp, nil
}

// Storage exposes the underlying backend.
func (cp *Corpus) Storage() Storage { return cp.storage }

// Observe records a single IRI (or string) and returns an Observation.
//
// Internally: builds an Event list for the IRI, then applies each event
// through the Reducer registry inside a single storage transaction. The
// event list is transient today — a future commit can persist it and
// replay against alternate reducers for re-runnable inference. See
// event.go and reducer.go.
func (cp *Corpus) Observe(input interface{}) (*Observation, error) {
	iri, err := coerceIdentifier(input)
	if err != nil {
		return nil, err
	}
	events := cp.eventsForIRI(iri)

	var cluster *Cluster
	err = cp.storage.Transaction(func() error {
		for _, e := range events {
			result := ApplyEvent(e, cp.storage)
			if _, ok := e.(EventClusterAddition); ok {
				if c, _ := result.(*Cluster); c != nil {
					cluster = c
				}
			}
		}
		cp.storage.RecordObservation(iri.Canonical())
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &Observation{corpus: cp, Identifier: iri, Cluster: cluster}, nil
}

// Reinfer drops every materialized view (host counts, position stats,
// clusters, …) and rebuilds them by replaying the source-IRI log
// through the current events + reducers pipeline. Useful for:
//
//   - Tuning thresholds (swap a Corpus constant, call Reinfer)
//   - Swapping the classifier (open the Corpus with a different
//     classifier, call Reinfer — events are re-derived from raw IRIs)
//   - Recovering after a Reducer-set change
//
// Wrapped in a single backend transaction so a mid-replay failure
// leaves the prior views intact.
func (cp *Corpus) Reinfer() error {
	return cp.storage.Transaction(func() error {
		var iris []string
		cp.storage.EachObservedIRI(func(c string) { iris = append(iris, c) })
		cp.storage.ClearMaterializedViews()
		for _, canonical := range iris {
			iri, err := Parse(canonical)
			if err != nil {
				return err
			}
			for _, e := range cp.eventsForIRI(iri) {
				ApplyEvent(e, cp.storage)
			}
		}
		return nil
	})
}

// ObservedIRICount returns the size of the source-IRI log.
func (cp *Corpus) ObservedIRICount() int {
	return cp.storage.ObservedIRICount()
}

// ProposeRecognizers scans observed values for shape patterns that recur
// frequently enough to suggest a new Recognizer. Returns
// RecognizerProposal records; nothing is automatically applied — each
// proposal carries enough evidence for a human to judge whether to bake
// the Recognizer in.
//
// Strategies are pluggable; the default set lives in
// DefaultProposalStrategies. Pass strategies = nil for the default;
// pass an empty slice to disable all detection (useful for tests).
// ActivateProposal promotes a RecognizerProposal into a live Recognizer
// for this corpus.
//
// Mechanics:
//   1. Synthesize a *SynthesizedRecognizer from the proposal's prefix.
//   2. Switch to a per-corpus classifier if we were sharing the global
//      DefaultClassifier — keeps the activation from leaking to other
//      corpora using the same singleton.
//   3. Register the Recognizer on the classifier so the ensemble picks
//      it up on the next Classify call.
//   4. Persist the activation in storage so reopens re-apply it.
//   5. Reinfer so existing observations get re-classified through the
//      new Recognizer.
//
// Returns the synthesized Recognizer.
func (cp *Corpus) ActivateProposal(p RecognizerProposal) (*SynthesizedRecognizer, error) {
	r := SynthesizedRecognizerFromProposal(p)
	cp.ensurePerCorpusClassifier()
	cp.Classifier.RegisterRecognizer(r)
	cp.storage.RecordActivatedRecognizer(r.Dump())
	if err := cp.Reinfer(); err != nil {
		return r, err
	}
	return r, nil
}

// ActivateProposalsAbove activates every proposal whose coverage clears
// the threshold. Convenience for `iriq --propose-recognizers --activate-above`.
func (cp *Corpus) ActivateProposalsAbove(coverageThreshold float64, opts ProposalOptions) ([]*SynthesizedRecognizer, error) {
	proposals := cp.ProposeRecognizers(nil, opts)
	var activated []*SynthesizedRecognizer
	for _, p := range proposals {
		if p.Coverage < coverageThreshold {
			continue
		}
		r, err := cp.ActivateProposal(p)
		if err != nil {
			return activated, err
		}
		activated = append(activated, r)
	}
	return activated, nil
}

// ActivatedRecognizerCount returns the number of persisted activations.
func (cp *Corpus) ActivatedRecognizerCount() int {
	return cp.storage.ActivatedRecognizerCount()
}

// ensurePerCorpusClassifier swaps cp.Classifier off the global default
// the first time we need to mutate it. Without this, activating a
// proposal would register the new Recognizer on DefaultClassifier and
// leak it to every other corpus sharing that singleton.
func (cp *Corpus) ensurePerCorpusClassifier() {
	if cp.Classifier != DefaultClassifier {
		return
	}
	cp.Classifier = NewSegmentClassifier()
}

// reapplyActivatedRecognizers reads stored activations from storage and
// registers each one on the corpus's classifier. Called from OpenCorpus
// so a reopened corpus retains its learned patterns.
func (cp *Corpus) reapplyActivatedRecognizers() {
	if cp.storage.ActivatedRecognizerCount() == 0 {
		return
	}
	cp.ensurePerCorpusClassifier()
	cp.storage.EachActivatedRecognizer(func(dump map[string]any) {
		if r, err := SynthesizedRecognizerFromDump(dump); err == nil {
			cp.Classifier.RegisterRecognizer(r)
		}
	})
}

func (cp *Corpus) ProposeRecognizers(strategies []ProposalStrategy, opts ProposalOptions) []RecognizerProposal {
	if strategies == nil {
		strategies = DefaultProposalStrategies
	}
	var out []RecognizerProposal
	for _, s := range strategies {
		out = append(out, s.Propose(cp.storage, opts)...)
	}
	return out
}

// EventsFor builds the ordered Event list for input without applying it.
// Useful for inspection, tests, and the future event-log persistence.
// Pure — no storage side-effects.
func (cp *Corpus) EventsFor(input interface{}) ([]Event, error) {
	iri, err := coerceIdentifier(input)
	if err != nil {
		return nil, err
	}
	return cp.eventsForIRI(iri), nil
}

func (cp *Corpus) eventsForIRI(iri *Identifier) []Event {
	hinted := DeriveHints(iri.PathSegments, cp.Classifier)
	rawShape := (&PathShape{Classifier: cp.Classifier, Hints: false}).FromEntries(hinted)
	hintedShape := (&PathShape{Classifier: cp.Classifier, Hints: true}).FromEntries(hinted)
	keyingHost := cp.effectiveHost(iri.Host)

	events := []Event{
		EventHostSeen{Host: keyingHost},
		EventPathLengthSeen{Length: len(iri.PathSegments)},
		EventRawShapeSeen{Shape: rawShape},
		EventFingerprintSeen{Shape: hintedShape},
	}

	prefix := ""
	for _, e := range hinted {
		events = append(events, EventPositionSeen{
			Position: PathPosition(keyingHost, prefix),
			Value:    e.Value, Type: e.Type,
		})
		prefix = prefix + "/" + placeholderFor(e)
	}

	key, host, scheme, shape := ClusterKeyForHost(iri, cp.Classifier, hintedShape, keyingHost)
	events = append(events, EventClusterAddition{
		Key: key, Host: host, Scheme: scheme, Shape: shape, Identifier: iri,
	})

	return events
}

// Normalize is the corpus-informed analog of iriq.Normalize. Implemented
// as a thin call into NormalizeIdentifierWithEvidence — Corpus satisfies
// the NormalizationEvidence interface via RenderPath / RenderQuery.
func (cp *Corpus) Normalize(input string) (string, error) {
	iri, err := Parse(input)
	if err != nil {
		return "", err
	}
	return cp.NormalizeIdentifier(iri), nil
}

func (cp *Corpus) NormalizeIdentifier(iri *Identifier) string {
	return NormalizeIdentifierWithEvidence(iri, cp.Classifier, true, cp)
}

// RenderPath satisfies NormalizationEvidence — renders the path using
// corpus-informed classifications (variability promotion, popular-outlier
// preservation). Always emits a leading "/" to anchor the URL and any
// trailing query.
func (cp *Corpus) RenderPath(iri *Identifier, _ *SegmentClassifier, _ bool) string {
	entries := cp.annotateSegments(iri)
	tokens := make([]string, len(entries))
	for i, e := range entries {
		tokens[i] = cp.corpusToken(e)
	}
	return "/" + strings.Join(tokens, "/")
}

// RenderQuery satisfies NormalizationEvidence — uses cluster-inferred
// param types when the cluster has enough samples, falling back to the
// classifier otherwise.
func (cp *Corpus) RenderQuery(iri *Identifier, _ *SegmentClassifier) string {
	return cp.renderQuery(iri)
}

// ParamsFor returns the inferred parameter summary for the cluster the input
// would fall into. Empty when no cluster has been observed for this shape.
func (cp *Corpus) ParamsFor(input interface{}) []ParamSummary {
	iri, err := coerceIdentifier(input)
	if err != nil {
		return nil
	}
	cluster := cp.clusterForIRI(iri)
	if cluster == nil {
		return nil
	}
	return cluster.ParamSummary()
}

func (cp *Corpus) clusterForIRI(iri *Identifier) *Cluster {
	hinted := DeriveHints(iri.PathSegments, cp.Classifier)
	shape := (&PathShape{Classifier: cp.Classifier, Hints: true}).FromEntries(hinted)
	key, _, _, _ := ClusterKeyForHost(iri, cp.Classifier, shape, cp.effectiveHost(iri.Host))
	return cp.storage.ClusterFor(key)
}

func (cp *Corpus) renderQuery(iri *Identifier) string {
	cluster := cp.clusterForIRI(iri)
	keys := iri.QueryParams.Keys()
	sortedKeys := append([]string(nil), keys...)
	sort.Strings(sortedKeys)
	parts := make([]string, 0, len(sortedKeys))
	for _, k := range sortedKeys {
		v, _ := iri.QueryParams.Get(k)
		t := cp.inferredParamType(cluster, k, v)
		parts = append(parts, k+"="+cp.renderParamValue(v, t))
	}
	return strings.Join(parts, "&")
}

func (cp *Corpus) inferredParamType(cluster *Cluster, name, value string) SegmentType {
	if cluster != nil {
		if stats := cluster.ParamStats[name]; stats != nil && stats.Total >= MinObservationsForInference {
			// Cluster.ParamType applies the :date quorum gate
			// (DateConfidenceThreshold). Both ParamSummary and corpus
			// normalize go through it so the views agree.
			return cluster.ParamType(name)
		}
	}
	return cp.Classifier.Classify(value)
}

func (cp *Corpus) renderParamValue(value string, t SegmentType) string {
	if t == TypeDate {
		if canon := CanonicalDate(value); canon != "" {
			return canon
		}
	}
	if cp.Classifier.Variable(t) {
		return "{" + string(t) + "}"
	}
	return value
}

// Explain returns a corpus-informed per-segment explanation.
func (cp *Corpus) Explain(input interface{}) []CorpusEntry {
	iri, err := coerceIdentifier(input)
	if err != nil {
		return nil
	}
	entries := cp.annotateSegments(iri)
	out := make([]CorpusEntry, len(entries))
	for i, e := range entries {
		out[i] = CorpusEntry{SegmentHint: e.hint, Classification: e.classification}
	}
	return out
}

// HostCounts / PathLengthCounts / RawShapeCounts / FingerprintCounts mirror
// the Ruby attr_readers. Each call materializes a fresh map from the backend
// — cheap for Memory, a table scan for SQLite.
func (cp *Corpus) HostCounts() map[string]int        { return cp.storage.HostCounts() }
func (cp *Corpus) PathLengthCounts() map[int]int     { return cp.storage.PathLengthCounts() }
func (cp *Corpus) RawShapeCounts() map[string]int    { return cp.storage.RawShapeCounts() }
func (cp *Corpus) FingerprintCounts() map[string]int { return cp.storage.FingerprintCounts() }

// MaxValuesPerPosition is the effective per-position cardinality cap.
func (cp *Corpus) MaxValuesPerPosition() int { return cp.storage.MaxValues() }

func (cp *Corpus) Clusters() []*Cluster { return cp.storage.Clusters() }
func (cp *Corpus) Size() int            { return cp.storage.ClusterSize() }

// StatsFor returns the PositionStats for (host, prefix) — nil if nothing has
// been observed there. Convenience wrapper that constructs a PathPosition.
func (cp *Corpus) StatsFor(host, prefix string) *PositionStats {
	return cp.storage.PositionStatsFor(PathPosition(host, prefix))
}

// Save persists the corpus.
//
//	Save("")           → flush the backend in place.
//	Save(same_path)    → idempotent: backend writes its own file.
//	Save(other_path)   → export to other_path as JSON, regardless of backend.
//
// In particular, calling Save with the SQLite backend's own path is a no-op
// (data is already on disk); passing a JSON path against a SQLite-backed
// corpus exports a snapshot.
func (cp *Corpus) Save(path string) error {
	backendPath := storagePath(cp.storage)
	if path == "" || path == backendPath {
		return cp.storage.Flush()
	}
	return cp.storage.SaveTo(path)
}

// storagePath returns the file path a storage is bound to, or "" if none.
func storagePath(s Storage) string {
	type pathed interface{ Path() string }
	if p, ok := s.(pathed); ok {
		return p.Path()
	}
	return ""
}

// Close releases backend resources (relevant for SQLite).
func (cp *Corpus) Close() error { return cp.storage.Close() }

// Batch wraps many observations in a single backend transaction. SQLite
// batches turn O(observations) fsyncs into one; Memory/JSON are no-ops.
func (cp *Corpus) Batch(fn func() error) error { return cp.storage.Batch(fn) }

// --- internals --------------------------------------------------------------

type annotated struct {
	hint           SegmentHint
	prefix         string
	classification Classification
}

func (cp *Corpus) annotateSegments(iri *Identifier) []annotated {
	hinted := DeriveHints(iri.PathSegments, cp.Classifier)
	out := make([]annotated, len(hinted))
	prefix := ""
	keyingHost := cp.effectiveHost(iri.Host)
	for i, entry := range hinted {
		stats := cp.storage.PositionStatsFor(PathPosition(keyingHost, prefix))
		cls := cp.classify(entry, stats)
		out[i] = annotated{hint: entry, prefix: prefix, classification: cls}
		prefix = prefix + "/" + placeholderFor(entry)
	}
	return out
}

func placeholderFor(e SegmentHint) string {
	if !e.Variable {
		return e.Value
	}
	if e.Hint != "" {
		return "{" + e.Hint + "}"
	}
	return "{" + string(e.Type) + "}"
}

// stableVariableType reports whether a variable-classified segment is one
// of the types where a dominant value should still be preserved as a
// literal. Covers shape-y types (Version/Locale/Currency/Boolean) plus
// Slug/OpaqueID — those often turn out to be route literals like
// `/users/{id}/create-new` or static reference codes.
func stableVariableType(t SegmentType) bool {
	switch t {
	case TypeVersion, TypeLocale, TypeCurrency, TypeBoolean,
		TypeSlug, TypeOpaqueID:
		return true
	}
	return false
}

func (cp *Corpus) classify(entry SegmentHint, stats *PositionStats) Classification {
	if stats == nil || stats.Total == 0 {
		if entry.Variable {
			return ClassVariableIdentifier
		}
		return ClassAmbiguous
	}
	if entry.Variable && !stableVariableType(entry.Type) {
		return ClassVariableIdentifier
	}

	value := entry.Value
	total := stats.Total
	variableFrac := stats.VariableFraction(cp.Classifier)
	cardinalityFrac := float64(stats.Cardinality()) / float64(total)
	enoughData := total >= MinObservationsForInference
	valueFrac := stats.ValueFraction(value)

	// For shape-y variable types, a dominant value wins → :stable_literal;
	// otherwise fall back to :variable_identifier (per-type placeholder).
	if entry.Variable {
		if valueFrac >= StableLiteralThreshold {
			return ClassStableLiteral
		}
		return ClassVariableIdentifier
	}

	switch {
	case enoughData && variableFrac >= VariableDominanceThreshold:
		if _, present := stats.ValueCounts[value]; present {
			return ClassRareLiteral
		}
		return ClassAmbiguous
	case valueFrac >= StableLiteralThreshold:
		return ClassStableLiteral
	case enoughData && highCardinalityLiteralPosition(stats, cardinalityFrac):
		if popularOutlier(stats, value) {
			return ClassStableLiteral
		}
		return ClassCorpusInferredVariable
	case stats.Cardinality() == 1:
		return ClassStableLiteral
	default:
		if _, present := stats.ValueCounts[value]; present {
			return ClassRareLiteral
		}
		return ClassAmbiguous
	}
}

func highCardinalityLiteralPosition(stats *PositionStats, cardFrac float64) bool {
	if cardFrac >= LiteralUniquenessThreshold {
		return true
	}
	return cardFrac >= LiteralUniquenessModerateThreshold && stats.Cardinality() >= MinCardinalityForInference
}

func popularOutlier(stats *PositionStats, value string) bool {
	count := stats.ValueCounts[value]
	if count < PopularMinCount {
		return false
	}
	baseline := 1.0 / float64(stats.Cardinality())
	return stats.ValueFraction(value) >= PopularBaselineMultiple*baseline
}

func (cp *Corpus) corpusToken(a annotated) string {
	switch a.classification {
	case ClassVariableIdentifier, ClassCorpusInferredVariable:
		return cp.placeholderForVariable(a)
	default:
		return a.hint.Value
	}
}

func (cp *Corpus) placeholderForVariable(a annotated) string {
	// Dates render in canonical ISO form rather than as a `{date}` placeholder
	// — matches Iriq.normalize's path canonicalization and the renderParamValue
	// query-param branch.
	if a.hint.Type == TypeDate {
		if canon := CanonicalDate(a.hint.Value); canon != "" {
			return canon
		}
	}
	if a.hint.Variable {
		if a.hint.Hint != "" {
			return "{" + a.hint.Hint + "}"
		}
		return "{" + string(a.hint.Type) + "}"
	}
	var lastLiteral string
	for _, part := range strings.Split(a.prefix, "/") {
		if part == "" || strings.HasPrefix(part, "{") {
			continue
		}
		lastLiteral = part
	}
	if lastLiteral != "" {
		return "{" + Singularize(lastLiteral) + "}"
	}
	return "{value}"
}

// LoadCorpus loads a JSON corpus (or opens any supported file via the
// extension-based dispatch). Kept as a top-level for backward compatibility.
func LoadCorpus(path string) (*Corpus, error) {
	return OpenCorpus(path)
}

// LoadCorpusFromBytes parses a JSON-shaped dump from raw bytes.
func LoadCorpusFromBytes(data []byte) (*Corpus, error) {
	mem := NewMemoryStorage(DefaultMaxValuesPerPosition)
	if err := loadMemoryFromJSON(mem, data); err != nil {
		return nil, err
	}
	return NewCorpusWithStorage(DefaultClassifier, mem), nil
}
