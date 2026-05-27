package iriq

import "strings"

// Clusterer groups many identifiers by host + path shape.
//
// Implemented as a thin wrapper over MemoryStorage — the same code path
// Corpus uses for the cluster portion of its state, so there's only one
// place that knows how clusters get stored.
type Clusterer struct {
	Classifier *SegmentClassifier
	storage    *MemoryStorage
}

func NewClusterer(c *SegmentClassifier) *Clusterer {
	if c == nil {
		c = DefaultClassifier
	}
	return &Clusterer{Classifier: c, storage: NewMemoryStorage(0)}
}

// Add records the input under its cluster key. If `shape` is non-empty it
// overrides the auto-derived shape (used by Corpus to share a single
// hinted-shape computation).
func (c *Clusterer) Add(input interface{}, shape string) (*Cluster, error) {
	iri, err := coerceIdentifier(input)
	if err != nil {
		return nil, err
	}
	key, host, scheme, finalShape := ClusterKeyFor(iri, c.Classifier, shape)
	return c.storage.AddToCluster(key, host, scheme, finalShape, iri), nil
}

// Clusters returns clusters in insertion order.
func (c *Clusterer) Clusters() []*Cluster { return c.storage.Clusters() }

func (c *Clusterer) Size() int { return c.storage.ClusterSize() }

// Explain returns a per-segment annotation combining classifier output with
// the cluster's observed stability — positions that are factually stable get
// marked variable: false even if the classifier would otherwise call them
// variable.
type ExplainEntry struct {
	SegmentHint
	Stable bool
}

func (c *Clusterer) Explain(input interface{}) ([]ExplainEntry, error) {
	iri, err := coerceIdentifier(input)
	if err != nil {
		return nil, err
	}
	key, _, _, _ := ClusterKeyFor(iri, c.Classifier, "")
	var stats []SegmentPositionStat
	for _, cluster := range c.storage.Clusters() {
		if cluster.Key == key {
			stats = cluster.SegmentStats()
			break
		}
	}
	hinted := DeriveHints(iri.PathSegments, c.Classifier)
	out := make([]ExplainEntry, len(hinted))
	for i, entry := range hinted {
		stable := i < len(stats) && stats[i].Stable
		entry.Variable = !stable && entry.Variable
		out[i] = ExplainEntry{SegmentHint: entry, Stable: stable}
	}
	return out, nil
}

// ClusterKeyFor derives the cluster key tuple [key, host, scheme, shape] for
// an identifier. URL inputs cluster by host + hinted shape; URNs cluster by
// namespace + value shape. Pass a non-empty shape override to skip the
// recomputation (URN inputs always derive their own).
func ClusterKeyFor(iri *Identifier, c *SegmentClassifier, shape string) (key, host, scheme, finalShape string) {
	return ClusterKeyForHost(iri, c, shape, iri.Host)
}

// ClusterKeyForHost lets callers (Corpus, when HostStrategy collapses
// subdomains or ignores the host) override iri.Host in the key.
func ClusterKeyForHost(iri *Identifier, c *SegmentClassifier, shape, hostOverride string) (key, host, scheme, finalShape string) {
	if iri.IsURN() {
		ns, value, _ := strings.Cut(iri.NSS, ":")
		if value != "" {
			finalShape = urnValueShape(ns, value, c)
		}
		key = "urn:" + ns + ":" + finalShape
		return key, "", "urn", key
	}
	if shape == "" {
		shape = (&PathShape{Classifier: c, Hints: true}).For(iri.PathSegments)
	}
	finalShape = shape
	host = hostOverride
	scheme = iri.Scheme
	key = iri.Scheme + "://" + host + shape
	return
}

func urnValueShape(ns, value string, c *SegmentClassifier) string {
	entries := DeriveHints([]string{ns, value}, c)
	entry := entries[len(entries)-1]
	if !entry.Variable {
		return entry.Value
	}
	if entry.Hint != "" {
		return "{" + entry.Hint + "}"
	}
	return "{" + string(entry.Type) + "}"
}

// coerceIdentifier accepts either an *Identifier or a string.
func coerceIdentifier(input interface{}) (*Identifier, error) {
	switch v := input.(type) {
	case *Identifier:
		return v, nil
	case string:
		return Parse(v)
	default:
		return nil, newParseError("coerce: unsupported input type")
	}
}
