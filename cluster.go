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
}

func NewCluster(key, host, scheme, shape string) *Cluster {
	return &Cluster{Key: key, Host: host, Scheme: scheme, Shape: shape}
}

func (c *Cluster) Add(iri *Identifier) {
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
