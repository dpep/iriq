package iriq

// DefaultMaxValuesPerPosition mirrors PositionStats::DEFAULT_MAX_VALUES.
// Existing tracked values still receive increments after the cap is hit;
// only NEW distinct values are dropped.
const DefaultMaxValuesPerPosition = 5_000

// PositionStats holds rolling frequency counts for a single
// (host, prefix-shape, position). Value cardinality is capped so a
// high-entropy position (UUIDs, timestamps) doesn't grow without bound.
type PositionStats struct {
	ValueCounts map[string]int
	TypeCounts  map[SegmentType]int
	Total       int
	MaxValues   int
}

func NewPositionStats(maxValues int) *PositionStats {
	if maxValues <= 0 {
		maxValues = DefaultMaxValuesPerPosition
	}
	return &PositionStats{
		ValueCounts: map[string]int{},
		TypeCounts:  map[SegmentType]int{},
		MaxValues:   maxValues,
	}
}

func (p *PositionStats) Observe(value string, t SegmentType) {
	p.Total++
	p.TypeCounts[t]++
	if _, present := p.ValueCounts[value]; present || len(p.ValueCounts) < p.MaxValues {
		p.ValueCounts[value]++
	}
}

func (p *PositionStats) Cardinality() int { return len(p.ValueCounts) }

// VariableFraction returns the share of observations whose classifier-derived
// type was variable (anything other than :literal).
func (p *PositionStats) VariableFraction(c *SegmentClassifier) float64 {
	if p.Total == 0 {
		return 0
	}
	v := 0
	for t, n := range p.TypeCounts {
		if c.Variable(t) {
			v += n
		}
	}
	return float64(v) / float64(p.Total)
}

func (p *PositionStats) ValueFraction(value string) float64 {
	if p.Total == 0 {
		return 0
	}
	return float64(p.ValueCounts[value]) / float64(p.Total)
}

// DominantType returns the SegmentType with the largest count in TypeCounts.
// On ties, returns the lexicographically smallest type so the answer is
// deterministic across runs (Go's map iteration order is randomized;
// Ruby's max_by returns the first-inserted max, which is also deterministic
// per-process — and lexicographic tie-break keeps Ruby↔Go behavior aligned
// without requiring insertion order).
func (p *PositionStats) DominantType() SegmentType {
	var dom SegmentType
	var domN int
	first := true
	for t, n := range p.TypeCounts {
		if first || n > domN || (n == domN && string(t) < string(dom)) {
			dom = t
			domN = n
			first = false
		}
	}
	return dom
}
