package iriq

import "strings"

// Classification labels mirror the symbols Ruby's Corpus#explain emits.
type Classification string

const (
	ClassStableLiteral           Classification = "stable_literal"
	ClassVariableIdentifier      Classification = "variable_identifier"
	ClassRareLiteral             Classification = "rare_literal"
	ClassAmbiguous               Classification = "ambiguous"
	ClassCorpusInferredVariable  Classification = "corpus_inferred_variable"
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
type Corpus struct {
	Classifier           *SegmentClassifier
	MaxValuesPerPosition int

	HostCounts        map[string]int
	PathLengthCounts  map[int]int
	RawShapeCounts    map[string]int
	FingerprintCounts map[string]int

	// position_stats keyed by (host, prefix). Insertion order preserved via positionKeys.
	positionStats map[positionKey]*PositionStats
	positionKeys  []positionKey

	clusterer *Clusterer
}

type positionKey struct {
	Host   string
	Prefix string
}

func NewCorpus() *Corpus { return NewCorpusWith(DefaultClassifier, DefaultMaxValuesPerPosition) }

func NewCorpusWith(c *SegmentClassifier, maxValues int) *Corpus {
	if c == nil {
		c = DefaultClassifier
	}
	if maxValues <= 0 {
		maxValues = DefaultMaxValuesPerPosition
	}
	return &Corpus{
		Classifier:           c,
		MaxValuesPerPosition: maxValues,
		HostCounts:           map[string]int{},
		PathLengthCounts:     map[int]int{},
		RawShapeCounts:       map[string]int{},
		FingerprintCounts:    map[string]int{},
		positionStats:        map[positionKey]*PositionStats{},
		clusterer:            NewClusterer(c),
	}
}

// Observe records a single IRI (or string) and returns an Observation.
func (cp *Corpus) Observe(input interface{}) (*Observation, error) {
	iri, err := coerceIdentifier(input)
	if err != nil {
		return nil, err
	}
	hinted := DeriveHints(iri.PathSegments, cp.Classifier)
	cp.recordAggregates(iri, hinted)
	hintedShape := (&PathShape{Classifier: cp.Classifier, Hints: true}).FromEntries(hinted)
	cluster, _ := cp.clusterer.Add(iri, hintedShape)
	return &Observation{corpus: cp, Identifier: iri, Cluster: cluster}, nil
}

// Normalize is the corpus-informed analog of Iriq.Normalize.
func (cp *Corpus) Normalize(input string) (string, error) {
	iri, err := Parse(input)
	if err != nil {
		return "", err
	}
	return cp.NormalizeIdentifier(iri), nil
}

func (cp *Corpus) NormalizeIdentifier(iri *Identifier) string {
	if iri.IsURN() || len(iri.PathSegments) == 0 {
		return NormalizeIdentifier(iri, cp.Classifier, true)
	}
	entries := cp.annotateSegments(iri)
	tokens := make([]string, len(entries))
	for i, e := range entries {
		tokens[i] = cp.corpusToken(e)
	}
	var b strings.Builder
	if iri.Scheme != "" {
		b.WriteString(iri.Scheme)
		b.WriteString("://")
	}
	if iri.Host != "" {
		b.WriteString(iri.Host)
	}
	if iri.Port != 0 {
		b.WriteByte(':')
		b.WriteString(itoa(iri.Port))
	}
	b.WriteByte('/')
	b.WriteString(strings.Join(tokens, "/"))
	return b.String()
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

func (cp *Corpus) Clusters() []*Cluster { return cp.clusterer.Clusters() }

func (cp *Corpus) Size() int { return cp.clusterer.Size() }

// StatsFor returns the PositionStats for (host, prefix) — nil if nothing has
// been observed there.
func (cp *Corpus) StatsFor(host, prefix string) *PositionStats {
	return cp.positionStats[positionKey{host, prefix}]
}

func (cp *Corpus) recordAggregates(iri *Identifier, hinted []SegmentHint) {
	if iri.Host != "" {
		cp.HostCounts[iri.Host]++
	}
	cp.PathLengthCounts[len(iri.PathSegments)]++

	raw := (&PathShape{Classifier: cp.Classifier, Hints: false}).FromEntries(hinted)
	fp := (&PathShape{Classifier: cp.Classifier, Hints: true}).FromEntries(hinted)
	cp.RawShapeCounts[raw]++
	cp.FingerprintCounts[fp]++

	cp.recordPositionStats(iri, hinted)
}

func (cp *Corpus) recordPositionStats(iri *Identifier, hinted []SegmentHint) {
	prefix := ""
	for _, entry := range hinted {
		key := positionKey{iri.Host, prefix}
		stats, ok := cp.positionStats[key]
		if !ok {
			stats = NewPositionStats(cp.MaxValuesPerPosition)
			cp.positionStats[key] = stats
			cp.positionKeys = append(cp.positionKeys, key)
		}
		stats.Observe(entry.Value, entry.Type)
		prefix = prefix + "/" + placeholderFor(entry)
	}
}

type annotated struct {
	hint           SegmentHint
	prefix         string
	classification Classification
}

func (cp *Corpus) annotateSegments(iri *Identifier) []annotated {
	hinted := DeriveHints(iri.PathSegments, cp.Classifier)
	out := make([]annotated, len(hinted))
	prefix := ""
	for i, entry := range hinted {
		stats := cp.positionStats[positionKey{iri.Host, prefix}]
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

func (cp *Corpus) classify(entry SegmentHint, stats *PositionStats) Classification {
	if stats == nil || stats.Total == 0 {
		if entry.Variable {
			return ClassVariableIdentifier
		}
		return ClassAmbiguous
	}
	if entry.Variable {
		return ClassVariableIdentifier
	}
	value := entry.Value
	total := stats.Total
	variableFrac := stats.VariableFraction(cp.Classifier)
	cardinalityFrac := float64(stats.Cardinality()) / float64(total)
	enoughData := total >= MinObservationsForInference
	valueFrac := stats.ValueFraction(value)

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
	if a.hint.Variable {
		if a.hint.Hint != "" {
			return "{" + a.hint.Hint + "}"
		}
		return "{" + string(a.hint.Type) + "}"
	}
	// corpus-inferred variable: classifier said literal, corpus says otherwise.
	// Derive a hint from the prefix's last literal segment.
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

// positionKeysOrdered exposes the deterministic insertion order — used by the
// JSON dump path to keep Ruby/Go round-trips identical.
func (cp *Corpus) positionKeysOrdered() []positionKey { return cp.positionKeys }
