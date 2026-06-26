package iriq

import (
	"math"
	"sort"
)

// MaxClusterExamples mirrors Cluster::MAX_EXAMPLES.
const MaxClusterExamples = 10

// DateConfidenceThreshold mirrors Ruby's Cluster::DATE_CONFIDENCE_THRESHOLD.
// Share of date-typed observations a param needs before the corpus promotes
// it to :date — 8-digit IDs in the 1900..2100 range look like YYYYMMDD by
// accident, so we require quorum before canonicalizing.
const DateConfidenceThreshold = 0.8

// NumberConfidenceThreshold + NumberSubtypeThreshold gate the :number
// umbrella. Promote to :number when combined integer + float observations
// dominate (≥ threshold) AND neither subtype alone is the clear winner
// (each below subtype threshold).
const (
	NumberConfidenceThreshold = 0.8
	NumberSubtypeThreshold    = 0.8
)

// Param classification is a confidence ladder: constant → string → enum. A
// single-valued param is a constant (rendered as-is); one that varies but isn't
// a trustworthy enum is TypeString (a generic placeholder); a bounded,
// well-supported value set is TypeEnum.
//
// Enum* thresholds. Promote a param to TypeEnum when the corpus has seen enough
// samples to trust the bound (EnumMinObservations), the *established* values
// — those seen at least EnumMinValueCount times — are few (EnumMaxCardinality)
// and cover nearly all observations (EnumMinCoverage). Rare one-off values are
// stragglers, not disqualifiers: this keeps a single brand-new value from
// knocking an established enum back down (the observe-before-normalize case).
const (
	EnumMinObservations = 20
	EnumMaxCardinality  = 10
	EnumMinValueCount   = 3
	EnumMinCoverage     = 0.9
	// An enum is a bounded *set*: a single repeated value is a constant, not
	// an enum, so it takes at least two established members to qualify.
	EnumMinMembers = 2
)

// StringMinDistinct — a literal-valued param that has taken on at least this
// many distinct values varies, so it's TypeString rather than a fixed constant.
const StringMinDistinct = 2

// ConfidenceSmoothing — confidence = total / (total + K): a monotone curve that
// is 0.5 at K observations and asymptotes to 1.0. The type names our guess;
// this number says how much evidence backs it.
const ConfidenceSmoothing = 15

// Year* thresholds. Promote an :integer position to :year when observed
// values cluster in the 1900..2100 window with enough samples and a
// modest spread of distinct values.
const (
	YearRangeMin        = 1900
	YearRangeMax        = 2100
	YearMinObservations = 5
	YearMinDistinct     = 2
	YearMaxDistinct     = 150
)

// isYearPosition reports whether a position's observed integer range
// matches the year window.
func isYearPosition(t SegmentType, stats *PositionStats) bool {
	if t != TypeInteger {
		return false
	}
	if stats.NumericCount == 0 {
		return false
	}
	card := stats.Cardinality()
	if card < YearMinDistinct || card > YearMaxDistinct {
		return false
	}
	if stats.Total < YearMinObservations {
		return false
	}
	if stats.NumericMin < YearRangeMin || stats.NumericMin > YearRangeMax {
		return false
	}
	if stats.NumericMax < YearRangeMin || stats.NumericMax > YearRangeMax {
		return false
	}
	return true
}

// HTTPStatus* thresholds mirror Cluster::HTTP_STATUS_* in Ruby — promote
// an integer position to TypeHTTPStatus when values cluster in 100..599
// with enough samples and a bounded distinct set.
const (
	HTTPStatusRangeMin        = 100
	HTTPStatusRangeMax        = 599
	HTTPStatusMinObservations = 5
	HTTPStatusMinDistinct     = 2
	HTTPStatusMaxDistinct     = 30
)

func isHTTPStatusPosition(t SegmentType, stats *PositionStats) bool {
	if t != TypeInteger {
		return false
	}
	if stats.NumericCount == 0 {
		return false
	}
	card := stats.Cardinality()
	if card < HTTPStatusMinDistinct || card > HTTPStatusMaxDistinct {
		return false
	}
	if stats.Total < HTTPStatusMinObservations {
		return false
	}
	if stats.NumericMin < HTTPStatusRangeMin || stats.NumericMin > HTTPStatusRangeMax {
		return false
	}
	if stats.NumericMax < HTTPStatusRangeMin || stats.NumericMax > HTTPStatusRangeMax {
		return false
	}
	return true
}

// SegmentPositionStat is the per-position summary surfaced via
// Cluster.SegmentStats — one entry per path position.
type SegmentPositionStat struct {
	Position int
	Stable   bool
	Values   map[string]int
}

// Cluster groups identifiers that share a host + shape key, tracking
// examples and per-position frequency stats.
type Cluster struct {
	Key      string
	Host     string
	Scheme   string
	Shape    string
	Examples []*Identifier
	Count    int

	segmentCounts []map[string]int
	// ParamStats is keyed by query-param name and tracks presence + value
	// cardinality + type distribution per param — same machinery as a path
	// position, just indexed by ?key= instead of by position.
	ParamStats map[string]*PositionStats
	// maxValues is the per-param value cardinality cap. Allocated on Add when
	// a new param is first seen.
	maxValues int
	// exampleKeys dedupes Examples by canonical URL so a stream of
	// identical inputs doesn't fill the slot with copies.
	exampleKeys map[string]struct{}
}

func NewCluster(key, host, scheme, shape string) *Cluster {
	return NewClusterWith(key, host, scheme, shape, DefaultMaxValuesPerPosition)
}

func NewClusterWith(key, host, scheme, shape string, maxValues int) *Cluster {
	if maxValues <= 0 {
		maxValues = DefaultMaxValuesPerPosition
	}
	return &Cluster{
		Key: key, Host: host, Scheme: scheme, Shape: shape,
		ParamStats:  map[string]*PositionStats{},
		maxValues:   maxValues,
		exampleKeys: map[string]struct{}{},
	}
}

// ParamSummary returns a per-param row useful for display + corpus queries
// like Corpus.ParamsFor(url). When Type is TypeEnum, Values lists the
// distinct observed values (descending count, lex tie-break). NumericCount
// is non-zero when the position has at least one integer / float
// observation; Min/Max/Avg only meaningful in that case.
//
// ValueDistribution carries per-value fractions for TypeBoolean and
// TypeEnum positions (e.g. {"true": 0.97, "false": 0.03}).
// SubtypeDistribution carries the int-vs-float split for TypeNumber.
// KindDistribution carries the file-kind breakdown for TypeFile.
type ParamSummary struct {
	Name                string
	Count               int
	Type                SegmentType
	Confidence          float64
	Cardinality         int
	Presence            float64
	Values              []string // populated only for TypeEnum
	NumericCount        int
	Min                 float64
	Max                 float64
	Avg                 float64
	ValueDistribution   map[string]float64
	SubtypeDistribution map[SegmentType]float64
	KindDistribution    map[FileKind]float64
}

func (c *Cluster) ParamSummary() []ParamSummary {
	if len(c.ParamStats) == 0 {
		return nil
	}
	out := make([]ParamSummary, 0, len(c.ParamStats))
	for name, stats := range c.ParamStats {
		var presence float64
		if c.Count > 0 {
			presence = float64(stats.Total) / float64(c.Count)
		}
		row := ParamSummary{
			Name: name, Count: stats.Total, Type: c.ParamType(name),
			Confidence:  paramConfidence(stats),
			Cardinality: stats.Cardinality(), Presence: presence,
		}
		if row.Type == TypeEnum {
			row.Values = enumValues(stats)
		}
		if row.Type == TypeBoolean || row.Type == TypeEnum {
			row.ValueDistribution = valueDistribution(stats)
		}
		if row.Type == TypeNumber {
			row.SubtypeDistribution = subtypeDistribution(stats, []SegmentType{TypeInteger, TypeFloat})
		}
		if row.Type == TypeFile {
			row.KindDistribution = fileKindDistribution(stats)
		}
		if stats.NumericCount > 0 {
			row.NumericCount = stats.NumericCount
			row.Min = stats.NumericMin
			row.Max = stats.NumericMax
			row.Avg = stats.NumericAvg()
		}
		out = append(out, row)
	}
	// Stable order: by descending count, name asc.
	sortParamSummary(out)
	return out
}

// valueDistribution returns the per-value fraction over total observations,
// rounded to 4 decimals. Caller can iterate value_counts.Keys() if order is
// needed; the map itself is unordered.
func valueDistribution(stats *PositionStats) map[string]float64 {
	if stats.Total == 0 {
		return nil
	}
	out := make(map[string]float64, len(stats.ValueCounts))
	for v, n := range stats.ValueCounts {
		out[v] = roundFrac(float64(n) / float64(stats.Total))
	}
	return out
}

// fileKindDistribution buckets tracked file-typed values by kind and
// returns the per-kind fraction over total tracked observations. Values
// with no recognized extension bucket as FileKind("unknown"). Sums to
// ≤ 1.0 since value_counts caps at DefaultMaxValuesPerPosition.
func fileKindDistribution(stats *PositionStats) map[FileKind]float64 {
	if len(stats.ValueCounts) == 0 {
		return nil
	}
	total := 0
	for _, n := range stats.ValueCounts {
		total += n
	}
	if total == 0 {
		return nil
	}
	out := map[FileKind]float64{}
	counts := map[FileKind]int{}
	for v, n := range stats.ValueCounts {
		k := FileKindOf(v)
		if k == "" {
			k = "unknown"
		}
		counts[k] += n
	}
	for k, n := range counts {
		out[k] = roundFrac(float64(n) / float64(total))
	}
	return out
}

// subtypeDistribution slices type_counts to a specific subset and returns
// fractions per subtype, rounded to 4 decimals.
func subtypeDistribution(stats *PositionStats, subtypes []SegmentType) map[SegmentType]float64 {
	if stats.Total == 0 {
		return nil
	}
	out := map[SegmentType]float64{}
	for _, t := range subtypes {
		if n := stats.TypeCounts[t]; n > 0 {
			out[t] = roundFrac(float64(n) / float64(stats.Total))
		}
	}
	return out
}

// roundFrac rounds to 4 decimal places — match Ruby's `.round(4)` so
// JSON output is identical across runtimes.
func roundFrac(f float64) float64 {
	return math.Round(f*10000) / 10000
}

// enumValues returns the enum's member values — the established ones (seen
// enough to be real), sorted by descending count with a lex tie-break.
// Stragglers are excluded so the advertised set is what the corpus is actually
// confident about (mirrors Ruby's Cluster#enum_values).
func enumValues(stats *PositionStats) []string {
	keys := make([]string, 0, len(stats.ValueCounts))
	for k, n := range stats.ValueCounts {
		if n >= EnumMinValueCount {
			keys = append(keys, k)
		}
	}
	sort.Slice(keys, func(i, j int) bool {
		if stats.ValueCounts[keys[i]] != stats.ValueCounts[keys[j]] {
			return stats.ValueCounts[keys[i]] > stats.ValueCounts[keys[j]]
		}
		return keys[i] < keys[j]
	})
	return keys
}

// isEnum returns true when stats meets the Enum* bounds. Built around the
// *established* members (values seen at least EnumMinValueCount times) so a
// stray one-off value is a straggler, not a disqualifier.
func isEnum(stats *PositionStats) bool {
	if stats.Total < EnumMinObservations {
		return false
	}
	established := 0 // number of established members
	covered := 0     // observations they account for
	for _, n := range stats.ValueCounts {
		if n >= EnumMinValueCount {
			established++
			covered += n
		}
	}
	if established < EnumMinMembers || established > EnumMaxCardinality {
		return false
	}
	return float64(covered)/float64(stats.Total) >= EnumMinCoverage
}

// paramConfidence reports how much evidence backs the assigned type: monotone
// in observation count, 0.5 at ConfidenceSmoothing, asymptoting to 1.0.
// Rounded to two decimals to match the Ruby/Rust output.
func paramConfidence(stats *PositionStats) float64 {
	if stats.Total == 0 {
		return 0.0
	}
	c := float64(stats.Total) / float64(stats.Total+ConfidenceSmoothing)
	return math.Round(c*100) / 100
}

// ParamType returns the type the corpus is confident enough to call this
// param. Equals stats.DominantType() unless :date is dominant but below
// DateConfidenceThreshold, in which case it falls back to the most-common
// non-date type (or TypeLiteral when none exists). Shared by ParamSummary
// and Corpus.inferredParamType so both views agree.
func (c *Cluster) ParamType(name string) SegmentType {
	stats := c.ParamStats[name]
	if stats == nil || stats.Total == 0 {
		return ""
	}
	t := stats.DominantType()

	// Year wins over enum for numeric range columns — a "years 2020..2026"
	// position is more useful described as a ranged year than as an enum
	// of those specific values.
	if isYearPosition(t, stats) {
		return TypeYear
	}
	// HTTP status — 3-digit ints clustered in 100..599 are almost certainly
	// HTTP statuses. Same range-promotion pattern as year, tighter window.
	if isHTTPStatusPosition(t, stats) {
		return TypeHTTPStatus
	}

	// Enum check — bounded value set trumps the underlying value type.
	// Skip when the dominant type is already specific (:boolean carries
	// more meaning than a 2-value enum).
	if isEnum(stats) && t != TypeBoolean {
		return TypeEnum
	}

	// :date gate — demote when there isn't enough date-typed quorum.
	if t == TypeDate {
		if float64(stats.TypeCounts[TypeDate])/float64(stats.Total) >= DateConfidenceThreshold {
			return t
		}
		if alt := dominantExcluding(stats, TypeDate); alt != "" {
			return alt
		}
		return TypeLiteral
	}

	// :number umbrella — promote when ints + floats together dominate but
	// neither alone is the clear winner.
	if t == TypeInteger || t == TypeFloat {
		intFrac := float64(stats.TypeCounts[TypeInteger]) / float64(stats.Total)
		floatFrac := float64(stats.TypeCounts[TypeFloat]) / float64(stats.Total)
		if intFrac < NumberSubtypeThreshold &&
			floatFrac < NumberSubtypeThreshold &&
			(intFrac+floatFrac) >= NumberConfidenceThreshold {
			return TypeNumber
		}
	}

	// Param-name fallback — `?phone=...` overrides a generic literal/
	// opaque_id/slug with TypePhone when the value's shape was too weak
	// to detect on its own.
	if hint := ParamNameHint(name, t); hint != "" {
		return hint
	}

	// TypeString rung — a literal-valued param that has taken on more than one
	// distinct value varies, so it's a placeholder, not a fixed constant.
	// Below the enum bar (checked above), so we claim only "free-form text".
	if t == TypeLiteral && stats.Cardinality() >= StringMinDistinct {
		return TypeString
	}

	return t
}

// dominantExcluding returns the SegmentType with the highest count in
// stats.TypeCounts excluding `skip`. Lex tie-break for cross-runtime
// determinism. Returns "" when only the skipped type exists.
func dominantExcluding(stats *PositionStats, skip SegmentType) SegmentType {
	var best SegmentType
	var bestN int
	first := true
	for t, n := range stats.TypeCounts {
		if t == skip {
			continue
		}
		if first || n > bestN || (n == bestN && string(t) < string(best)) {
			best = t
			bestN = n
			first = false
		}
	}
	return best
}

// RegisterExampleKey lets backends restore the dedupe set when rehydrating
// a cluster from persistent storage. Callers that don't go through Add
// (e.g. JSON / SQLite load) should call this for each example so a
// later Observe doesn't reintroduce it.
func (c *Cluster) RegisterExampleKey(canon string) {
	if c.exampleKeys == nil {
		c.exampleKeys = map[string]struct{}{}
	}
	c.exampleKeys[canon] = struct{}{}
}

func (c *Cluster) Add(iri *Identifier) { c.AddWith(iri, DefaultClassifier) }

func (c *Cluster) AddWith(iri *Identifier, classifier *SegmentClassifier) {
	c.Count++
	if len(c.Examples) < MaxClusterExamples {
		if c.exampleKeys == nil {
			c.exampleKeys = map[string]struct{}{}
		}
		canon := iri.Canonical()
		if _, dup := c.exampleKeys[canon]; !dup {
			c.exampleKeys[canon] = struct{}{}
			c.Examples = append(c.Examples, iri)
		}
	}
	for i, seg := range iri.PathSegments {
		for len(c.segmentCounts) <= i {
			c.segmentCounts = append(c.segmentCounts, map[string]int{})
		}
		c.segmentCounts[i][seg]++
	}
	if classifier == nil {
		classifier = DefaultClassifier
	}
	if iri.QueryParams == nil {
		return
	}
	cap := c.maxValues
	if cap <= 0 {
		cap = DefaultMaxValuesPerPosition
	}
	for _, name := range iri.QueryParams.Keys() {
		v, _ := iri.QueryParams.Get(name)
		stats := c.ParamStats[name]
		if stats == nil {
			stats = NewPositionStats(cap)
			c.ParamStats[name] = stats
		}
		stats.Observe(v, classifier.Classify(v))
	}
}

// SegmentStats returns the per-position summary used by the clusterer's
// explain() and stable-position inference.
func (c *Cluster) SegmentStats() []SegmentPositionStat {
	out := make([]SegmentPositionStat, len(c.segmentCounts))
	for i, counts := range c.segmentCounts {
		dup := make(map[string]int, len(counts))
		for k, v := range counts {
			dup[k] = v
		}
		out[i] = SegmentPositionStat{Position: i, Stable: len(counts) == 1, Values: dup}
	}
	return out
}

// SegmentCounts exposes the raw per-position counters for serialization.
func (c *Cluster) SegmentCounts() []map[string]int { return c.segmentCounts }

// SetSegmentCounts is used by load/from-dump paths.
func (c *Cluster) SetSegmentCounts(counts []map[string]int) { c.segmentCounts = counts }

// sortParamSummary orders by descending count, then by name. Pulled out so
// it can be tested independently of the rest of Cluster.
func sortParamSummary(rows []ParamSummary) {
	// Tiny insertion sort — typical cluster has <10 params, this beats
	// pulling in sort.Slice + closure allocs.
	for i := 1; i < len(rows); i++ {
		for j := i; j > 0; j-- {
			a, b := rows[j-1], rows[j]
			if a.Count > b.Count || (a.Count == b.Count && a.Name <= b.Name) {
				break
			}
			rows[j-1], rows[j] = rows[j], rows[j-1]
		}
	}
}
