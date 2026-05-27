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

// Enum* thresholds. Promote a param to TypeEnum when the corpus has seen
// enough samples to trust the bound, the value set is small, each tracked
// value appears more than once, and tracked values cover nearly all
// observations.
const (
	EnumMinObservations = 20
	EnumMaxCardinality  = 10
	EnumMinValueCount   = 2
	EnumMinCoverage     = 0.95
)

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
		ParamStats: map[string]*PositionStats{},
		maxValues:  maxValues,
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
type ParamSummary struct {
	Name                string
	Count               int
	Type                SegmentType
	Cardinality         int
	Presence            float64
	Values              []string // populated only for TypeEnum
	NumericCount        int
	Min                 float64
	Max                 float64
	Avg                 float64
	ValueDistribution   map[string]float64
	SubtypeDistribution map[SegmentType]float64
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

// enumValues returns the distinct values tracked in stats, sorted by
// descending count with a lex tie-break (mirrors Ruby's Cluster#enum_values).
func enumValues(stats *PositionStats) []string {
	keys := make([]string, 0, len(stats.ValueCounts))
	for k := range stats.ValueCounts {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if stats.ValueCounts[keys[i]] != stats.ValueCounts[keys[j]] {
			return stats.ValueCounts[keys[i]] > stats.ValueCounts[keys[j]]
		}
		return keys[i] < keys[j]
	})
	return keys
}

// isEnum returns true when stats meets the Enum* bounds.
func isEnum(stats *PositionStats) bool {
	if stats.Total < EnumMinObservations {
		return false
	}
	card := stats.Cardinality()
	if card == 0 || card > EnumMaxCardinality {
		return false
	}
	covered := 0
	for _, n := range stats.ValueCounts {
		if n < EnumMinValueCount {
			return false
		}
		covered += n
	}
	return float64(covered)/float64(stats.Total) >= EnumMinCoverage
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

func (c *Cluster) Add(iri *Identifier) { c.AddWith(iri, DefaultClassifier) }

func (c *Cluster) AddWith(iri *Identifier, classifier *SegmentClassifier) {
	c.Count++
	if len(c.Examples) < MaxClusterExamples {
		c.Examples = append(c.Examples, iri)
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
