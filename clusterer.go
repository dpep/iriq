package iriq

import "strings"

// Clusterer groups many identifiers by host + path shape.
type Clusterer struct {
	Classifier *SegmentClassifier
	// Insertion-ordered map of cluster key -> cluster.
	keys     []string
	byKey    map[string]*Cluster
}

func NewClusterer(c *SegmentClassifier) *Clusterer {
	if c == nil {
		c = DefaultClassifier
	}
	return &Clusterer{Classifier: c, byKey: map[string]*Cluster{}}
}

// Add records the input under its cluster key. If `shape` is non-empty it
// overrides the auto-derived shape (used by Corpus to share a single
// hinted-shape computation).
func (c *Clusterer) Add(input interface{}, shape string) (*Cluster, error) {
	iri, err := coerceIdentifier(input)
	if err != nil {
		return nil, err
	}
	key, host, scheme, finalShape := c.clusterKey(iri, shape)
	cluster, ok := c.byKey[key]
	if !ok {
		cluster = NewCluster(key, host, scheme, finalShape)
		c.byKey[key] = cluster
		c.keys = append(c.keys, key)
	}
	cluster.Add(iri)
	return cluster, nil
}

// Clusters returns clusters in insertion order.
func (c *Clusterer) Clusters() []*Cluster {
	out := make([]*Cluster, 0, len(c.keys))
	for _, k := range c.keys {
		out = append(out, c.byKey[k])
	}
	return out
}

func (c *Clusterer) Size() int { return len(c.byKey) }

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
	key, _, _, _ := c.clusterKey(iri, "")
	cluster := c.byKey[key]
	var stats []SegmentPositionStat
	if cluster != nil {
		stats = cluster.SegmentStats()
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

func (c *Clusterer) clusterKey(iri *Identifier, shape string) (key, host, scheme, finalShape string) {
	if iri.IsURN() {
		ns, value, hasColon := strings.Cut(iri.NSS, ":")
		_ = hasColon
		if value != "" {
			finalShape = urnValueShape(ns, value, c.Classifier)
		}
		key = "urn:" + ns + ":" + finalShape
		return key, "", "urn", key
	}
	if shape == "" {
		shape = (&PathShape{Classifier: c.Classifier, Hints: true}).For(iri.PathSegments)
	}
	finalShape = shape
	host = iri.Host
	scheme = iri.Scheme
	key = iri.Scheme + "://" + iri.Host + shape
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
