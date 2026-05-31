package iriq

// MemoryStorage is the default backend — every counter and per-position
// frequency map lives in process memory. The JSON backend wraps it with
// load/save against a file; SQLite is an independent disk-backed alternative.
type MemoryStorage struct {
	maxValues  int
	classifier *SegmentClassifier

	hostCounts        map[string]int
	pathLengthCounts  map[int]int
	rawShapeCounts    map[string]int
	fingerprintCounts map[string]int

	positionStats map[Position]*PositionStats
	positionKeys  []Position

	clusters    map[string]*Cluster
	clusterKeys []string
}

func NewMemoryStorage(maxValues int) *MemoryStorage {
	return NewMemoryStorageWith(maxValues, DefaultClassifier)
}

// NewMemoryStorageWith lets callers (Corpus.OpenCorpus, tests) thread a
// specific classifier into the storage so per-cluster ParamStats classify
// query values with the same classifier the rest of the corpus uses.
func NewMemoryStorageWith(maxValues int, c *SegmentClassifier) *MemoryStorage {
	if maxValues <= 0 {
		maxValues = DefaultMaxValuesPerPosition
	}
	if c == nil {
		c = DefaultClassifier
	}
	return &MemoryStorage{
		maxValues:         maxValues,
		classifier:        c,
		hostCounts:        map[string]int{},
		pathLengthCounts:  map[int]int{},
		rawShapeCounts:    map[string]int{},
		fingerprintCounts: map[string]int{},
		positionStats:     map[Position]*PositionStats{},
		clusters:          map[string]*Cluster{},
	}
}

func (s *MemoryStorage) MaxValues() int                    { return s.maxValues }
func (s *MemoryStorage) Transaction(fn func() error) error { return fn() }
func (s *MemoryStorage) Batch(fn func() error) error       { return fn() }
func (s *MemoryStorage) Flush() error                      { return nil }
func (s *MemoryStorage) Close() error                      { return nil }

func (s *MemoryStorage) IncrementHost(host string) {
	// Empty host is meaningful for HostStrategyNone — every observation
	// collapses to "" — so we count it. Pre-strategy callers that pass
	// "" for non-URN identifiers (which always have a host) wouldn't hit
	// this path.
	s.hostCounts[host]++
}

func (s *MemoryStorage) IncrementPathLength(length int) { s.pathLengthCounts[length]++ }
func (s *MemoryStorage) IncrementRawShape(shape string) { s.rawShapeCounts[shape]++ }
func (s *MemoryStorage) IncrementFingerprint(shape string) {
	s.fingerprintCounts[shape]++
}

func (s *MemoryStorage) ObservePosition(pos Position, value string, t SegmentType) {
	stats, ok := s.positionStats[pos]
	if !ok {
		stats = NewPositionStats(s.maxValues)
		s.positionStats[pos] = stats
		s.positionKeys = append(s.positionKeys, pos)
	}
	stats.Observe(value, t)
}

func (s *MemoryStorage) AddToCluster(key, host, scheme, shape string, iri *Identifier) *Cluster {
	cluster, ok := s.clusters[key]
	if !ok {
		cluster = NewClusterWith(key, host, scheme, shape, s.maxValues)
		s.clusters[key] = cluster
		s.clusterKeys = append(s.clusterKeys, key)
	}
	cluster.AddWith(iri, s.classifier)
	return cluster
}

// ClusterFor is the O(1) lookup used by Corpus.Normalize / ParamsFor — nil
// if no cluster has been observed under this key yet.
func (s *MemoryStorage) ClusterFor(key string) *Cluster { return s.clusters[key] }

func (s *MemoryStorage) HostCounts() map[string]int        { return copyMapStringInt(s.hostCounts) }
func (s *MemoryStorage) PathLengthCounts() map[int]int     { return copyMapIntInt(s.pathLengthCounts) }
func (s *MemoryStorage) RawShapeCounts() map[string]int    { return copyMapStringInt(s.rawShapeCounts) }
func (s *MemoryStorage) FingerprintCounts() map[string]int { return copyMapStringInt(s.fingerprintCounts) }

func (s *MemoryStorage) PositionStatsFor(pos Position) *PositionStats {
	return s.positionStats[pos]
}

func (s *MemoryStorage) EachPositionStats(fn func(pos Position, stats *PositionStats)) {
	for _, k := range s.positionKeys {
		fn(k, s.positionStats[k])
	}
}

func (s *MemoryStorage) Clusters() []*Cluster {
	out := make([]*Cluster, 0, len(s.clusterKeys))
	for _, k := range s.clusterKeys {
		out = append(out, s.clusters[k])
	}
	return out
}

func (s *MemoryStorage) ClusterSize() int { return len(s.clusters) }

func (s *MemoryStorage) SaveTo(path string) error {
	return dumpMemoryToJSON(s, path)
}

func copyMapStringInt(m map[string]int) map[string]int {
	out := make(map[string]int, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

func copyMapIntInt(m map[int]int) map[int]int {
	out := make(map[int]int, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}
