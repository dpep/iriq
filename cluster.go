package iriq

// MaxClusterExamples mirrors Cluster::MAX_EXAMPLES.
const MaxClusterExamples = 10

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
// like Corpus.ParamsFor(url).
type ParamSummary struct {
	Name        string
	Count       int
	Type        SegmentType
	Cardinality int
	Presence    float64
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
		out = append(out, ParamSummary{
			Name: name, Count: stats.Total, Type: stats.DominantType(),
			Cardinality: stats.Cardinality(), Presence: presence,
		})
	}
	// Stable order: by descending count, name asc.
	sortParamSummary(out)
	return out
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
