package iriq

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
)

// CorpusDump is the on-disk JSON shape. Mirrors Corpus#dump in Ruby —
// compatible enough that corpus files written by either implementation can
// be loaded by the other.
type CorpusDump struct {
	HostCounts           map[string]int    `json:"host_counts"`
	PathLengthCounts     map[string]int    `json:"path_length_counts"` // keys are stringified ints
	RawShapeCounts       map[string]int    `json:"raw_shape_counts"`
	FingerprintCounts    map[string]int    `json:"fingerprint_counts"`
	MaxValuesPerPosition int               `json:"max_values_per_position"`
	PositionStats        [][]interface{}   `json:"position_stats"` // [[host, prefix, statsDump], ...]
	Clusterer            ClustererDump     `json:"clusterer"`
}

type ClustererDump struct {
	Clusters map[string]ClusterDump `json:"clusters"`
}

type ClusterDump struct {
	Key            string              `json:"key"`
	Host           string              `json:"host"`
	Scheme         string              `json:"scheme"`
	Shape          string              `json:"shape"`
	Count          int                 `json:"count"`
	Examples       []string            `json:"examples"`
	SegmentCounts  []map[string]int    `json:"segment_counts"`
}

type positionStatsDump struct {
	ValueCounts map[string]int `json:"value_counts"`
	TypeCounts  map[string]int `json:"type_counts"`
	Total       int            `json:"total"`
	MaxValues   int            `json:"max_values"`
}

// Dump produces the JSON-ready shape.
func (cp *Corpus) Dump() *CorpusDump {
	plc := make(map[string]int, len(cp.PathLengthCounts))
	for k, v := range cp.PathLengthCounts {
		plc[strconv.Itoa(k)] = v
	}
	ps := make([][]interface{}, 0, len(cp.positionKeys))
	for _, k := range cp.positionKeys {
		s := cp.positionStats[k]
		ps = append(ps, []interface{}{k.Host, k.Prefix, dumpPositionStats(s)})
	}
	cluDump := ClustererDump{Clusters: map[string]ClusterDump{}}
	for _, key := range cp.clusterer.keys {
		c := cp.clusterer.byKey[key]
		examples := make([]string, len(c.Examples))
		for i, e := range c.Examples {
			examples[i] = e.Canonical()
		}
		segCounts := c.SegmentCounts()
		if segCounts == nil {
			segCounts = []map[string]int{}
		}
		cluDump.Clusters[key] = ClusterDump{
			Key: c.Key, Host: c.Host, Scheme: c.Scheme, Shape: c.Shape,
			Count: c.Count, Examples: examples, SegmentCounts: segCounts,
		}
	}
	return &CorpusDump{
		HostCounts:           cp.HostCounts,
		PathLengthCounts:     plc,
		RawShapeCounts:       cp.RawShapeCounts,
		FingerprintCounts:    cp.FingerprintCounts,
		MaxValuesPerPosition: cp.MaxValuesPerPosition,
		PositionStats:        ps,
		Clusterer:            cluDump,
	}
}

func dumpPositionStats(p *PositionStats) positionStatsDump {
	tc := make(map[string]int, len(p.TypeCounts))
	for k, v := range p.TypeCounts {
		tc[string(k)] = v
	}
	return positionStatsDump{
		ValueCounts: p.ValueCounts,
		TypeCounts:  tc,
		Total:       p.Total,
		MaxValues:   p.MaxValues,
	}
}

// Save atomically writes the corpus to path (tmp file + rename).
func (cp *Corpus) Save(path string) error {
	dump := cp.Dump()
	data, err := json.Marshal(dump)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// LoadCorpus reads a corpus JSON file.
func LoadCorpus(path string) (*Corpus, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return LoadCorpusFromBytes(data)
}

// LoadCorpusFromBytes parses a corpus dump from raw JSON.
func LoadCorpusFromBytes(data []byte) (*Corpus, error) {
	// We deliberately decode into interface{} first so we can tolerate the
	// untyped position_stats triples written by both implementations.
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, err
	}
	cp := NewCorpus()
	if msg, ok := raw["max_values_per_position"]; ok {
		_ = json.Unmarshal(msg, &cp.MaxValuesPerPosition)
		if cp.MaxValuesPerPosition <= 0 {
			cp.MaxValuesPerPosition = DefaultMaxValuesPerPosition
		}
	}
	if msg, ok := raw["host_counts"]; ok {
		_ = json.Unmarshal(msg, &cp.HostCounts)
	}
	if msg, ok := raw["raw_shape_counts"]; ok {
		_ = json.Unmarshal(msg, &cp.RawShapeCounts)
	}
	if msg, ok := raw["fingerprint_counts"]; ok {
		_ = json.Unmarshal(msg, &cp.FingerprintCounts)
	}
	if msg, ok := raw["path_length_counts"]; ok {
		var plc map[string]int
		if err := json.Unmarshal(msg, &plc); err != nil {
			return nil, err
		}
		for k, v := range plc {
			n, err := strconv.Atoi(k)
			if err != nil {
				return nil, fmt.Errorf("path_length_counts key %q: %w", k, err)
			}
			cp.PathLengthCounts[n] = v
		}
	}
	if msg, ok := raw["position_stats"]; ok {
		var entries [][]interface{}
		if err := json.Unmarshal(msg, &entries); err != nil {
			return nil, err
		}
		for _, e := range entries {
			if len(e) != 3 {
				continue
			}
			host, _ := e[0].(string)
			prefix, _ := e[1].(string)
			subRaw, err := json.Marshal(e[2])
			if err != nil {
				return nil, err
			}
			var sd positionStatsDump
			if err := json.Unmarshal(subRaw, &sd); err != nil {
				return nil, err
			}
			ps := NewPositionStats(sd.MaxValues)
			ps.Total = sd.Total
			ps.ValueCounts = sd.ValueCounts
			if ps.ValueCounts == nil {
				ps.ValueCounts = map[string]int{}
			}
			ps.TypeCounts = map[SegmentType]int{}
			for k, v := range sd.TypeCounts {
				ps.TypeCounts[SegmentType(k)] = v
			}
			k := positionKey{host, prefix}
			cp.positionStats[k] = ps
			cp.positionKeys = append(cp.positionKeys, k)
		}
	}
	if msg, ok := raw["clusterer"]; ok {
		var cd ClustererDump
		if err := json.Unmarshal(msg, &cd); err != nil {
			return nil, err
		}
		cp.clusterer = NewClusterer(cp.Classifier)
		// Reconstruct in arbitrary order — Ruby's Hash#each preserves
		// insertion order but JSON itself doesn't, so we accept any order
		// after a round-trip.
		for key, c := range cd.Clusters {
			cluster := NewCluster(c.Key, c.Host, c.Scheme, c.Shape)
			cluster.Count = c.Count
			for _, s := range c.Examples {
				iri, err := Parse(s)
				if err != nil {
					return nil, err
				}
				cluster.Examples = append(cluster.Examples, iri)
			}
			cluster.SetSegmentCounts(c.SegmentCounts)
			cp.clusterer.byKey[key] = cluster
			cp.clusterer.keys = append(cp.clusterer.keys, key)
		}
	}
	return cp, nil
}

// MarshalJSON makes the dump struct emit Ruby-compatible JSON.
func (d *CorpusDump) MarshalJSON() ([]byte, error) {
	type alias CorpusDump
	return json.Marshal((*alias)(d))
}
