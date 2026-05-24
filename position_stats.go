package iriq

// DefaultMaxValuesPerPosition mirrors PositionStats::DEFAULT_MAX_VALUES.
const DefaultMaxValuesPerPosition = 1_000

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
