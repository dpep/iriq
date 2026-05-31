package iriq

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
)

// JSONStorage wraps a MemoryStorage with load/save against a JSON file.
// The on-disk shape matches the Ruby Corpus#dump output byte-for-byte
// (modulo key ordering, which neither runtime preserves through json
// marshal/unmarshal).
type JSONStorage struct {
	*MemoryStorage
	path string
}

// OpenJSONStorage creates or opens a JSON-backed corpus using the default
// classifier; pass a custom one via OpenJSONStorageWith.
func OpenJSONStorage(path string, maxValues int) (*JSONStorage, error) {
	return OpenJSONStorageWith(path, maxValues, DefaultClassifier)
}

// OpenJSONStorageWith creates or opens a JSON-backed corpus with an explicit
// classifier — used so cluster.ParamStats classify values consistently with
// the surrounding corpus.
func OpenJSONStorageWith(path string, maxValues int, c *SegmentClassifier) (*JSONStorage, error) {
	s := &JSONStorage{MemoryStorage: NewMemoryStorageWith(maxValues, c), path: path}
	info, err := os.Stat(path)
	if err == nil && info.Size() > 0 {
		if err := s.loadFromFile(path); err != nil {
			return nil, err
		}
	} else if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	return s, nil
}

func (s *JSONStorage) Path() string { return s.path }

func (s *JSONStorage) Flush() error { return s.SaveTo(s.path) }

func (s *JSONStorage) SaveTo(path string) error {
	return dumpMemoryToJSON(s.MemoryStorage, path)
}

func (s *JSONStorage) loadFromFile(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return loadMemoryFromJSON(s.MemoryStorage, data)
}

// --- On-disk format ---------------------------------------------------------

// corpusDump is the JSON shape. Lower-cased struct is intentional — this is
// purely an implementation detail of the JSON backend.
type corpusDump struct {
	HostCounts           map[string]int     `json:"host_counts"`
	PathLengthCounts     map[string]int     `json:"path_length_counts"`
	RawShapeCounts       map[string]int     `json:"raw_shape_counts"`
	FingerprintCounts    map[string]int     `json:"fingerprint_counts"`
	MaxValuesPerPosition int                `json:"max_values_per_position"`
	PositionStats        []positionStatsEntryDump `json:"position_stats"`
	Clusterer            clustererDumpShape `json:"clusterer"`
}

type clustererDumpShape struct {
	Clusters map[string]clusterDumpShape `json:"clusters"`
}

type clusterDumpShape struct {
	Key           string                            `json:"key"`
	Host          string                            `json:"host"`
	Scheme        string                            `json:"scheme"`
	Shape         string                            `json:"shape"`
	Count         int                               `json:"count"`
	Examples      []string                          `json:"examples"`
	SegmentCounts []map[string]int                  `json:"segment_counts"`
	// Always emit param_stats (even when empty) so Ruby-saved and Go-saved
	// dumps match byte-for-byte. Ruby's Cluster#dump always renders the key.
	ParamStats map[string]positionStatsDumpShape `json:"param_stats"`
}

type positionStatsDumpShape struct {
	ValueCounts map[string]int `json:"value_counts"`
	TypeCounts  map[string]int `json:"type_counts"`
	Total       int            `json:"total"`
	MaxValues   int            `json:"max_values"`
}

// positionDumpShape is the serialized form of an Iriq::Position — host,
// scope, locator. Scope is a string for cross-runtime parity.
type positionDumpShape struct {
	Host    string `json:"host"`
	Scope   string `json:"scope"`
	Locator string `json:"locator"`
}

// positionStatsEntryDump pairs a Position with its PositionStats in the
// corpus dump — the JSON wire form is { "position": {...}, "stats": {...} }
// so each entry round-trips with structured field names instead of a
// tuple of unnamed values.
type positionStatsEntryDump struct {
	Position positionDumpShape      `json:"position"`
	Stats    positionStatsDumpShape `json:"stats"`
}

func dumpMemoryToJSON(m *MemoryStorage, path string) error {
	plc := make(map[string]int, len(m.pathLengthCounts))
	for k, v := range m.pathLengthCounts {
		plc[strconv.Itoa(k)] = v
	}
	ps := make([]positionStatsEntryDump, 0, len(m.positionKeys))
	for _, k := range m.positionKeys {
		stats := m.positionStats[k]
		ps = append(ps, positionStatsEntryDump{
			Position: positionDumpShape{Host: k.Host, Scope: string(k.Scope), Locator: k.Locator},
			Stats:    positionStatsDumpFrom(stats),
		})
	}
	clu := clustererDumpShape{Clusters: map[string]clusterDumpShape{}}
	for _, key := range m.clusterKeys {
		c := m.clusters[key]
		examples := make([]string, len(c.Examples))
		for i, e := range c.Examples {
			examples[i] = e.Canonical()
		}
		seg := c.SegmentCounts()
		if seg == nil {
			seg = []map[string]int{}
		}
		// Always allocate the map so the JSON output renders `{}` rather than
		// nothing for paramless clusters (matches Ruby's Cluster#dump).
		params := make(map[string]positionStatsDumpShape, len(c.ParamStats))
		for name, stats := range c.ParamStats {
			params[name] = positionStatsDumpFrom(stats)
		}
		clu.Clusters[key] = clusterDumpShape{
			Key: c.Key, Host: c.Host, Scheme: c.Scheme, Shape: c.Shape,
			Count: c.Count, Examples: examples, SegmentCounts: seg,
			ParamStats: params,
		}
	}
	d := &corpusDump{
		HostCounts:           m.hostCounts,
		PathLengthCounts:     plc,
		RawShapeCounts:       m.rawShapeCounts,
		FingerprintCounts:    m.fingerprintCounts,
		MaxValuesPerPosition: m.maxValues,
		PositionStats:        ps,
		Clusterer:            clu,
	}
	data, err := json.Marshal(d)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func positionStatsDumpFrom(p *PositionStats) positionStatsDumpShape {
	tc := make(map[string]int, len(p.TypeCounts))
	for k, v := range p.TypeCounts {
		tc[string(k)] = v
	}
	return positionStatsDumpShape{
		ValueCounts: p.ValueCounts,
		TypeCounts:  tc,
		Total:       p.Total,
		MaxValues:   p.MaxValues,
	}
}

func loadMemoryFromJSON(m *MemoryStorage, data []byte) error {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	if msg, ok := raw["max_values_per_position"]; ok {
		_ = json.Unmarshal(msg, &m.maxValues)
		if m.maxValues <= 0 {
			m.maxValues = DefaultMaxValuesPerPosition
		}
	}
	if msg, ok := raw["host_counts"]; ok {
		_ = json.Unmarshal(msg, &m.hostCounts)
	}
	if msg, ok := raw["raw_shape_counts"]; ok {
		_ = json.Unmarshal(msg, &m.rawShapeCounts)
	}
	if msg, ok := raw["fingerprint_counts"]; ok {
		_ = json.Unmarshal(msg, &m.fingerprintCounts)
	}
	if msg, ok := raw["path_length_counts"]; ok {
		var plc map[string]int
		if err := json.Unmarshal(msg, &plc); err != nil {
			return err
		}
		for k, v := range plc {
			n, err := strconv.Atoi(k)
			if err != nil {
				return fmt.Errorf("path_length_counts key %q: %w", k, err)
			}
			m.pathLengthCounts[n] = v
		}
	}
	if msg, ok := raw["position_stats"]; ok {
		var entries []positionStatsEntryDump
		if err := json.Unmarshal(msg, &entries); err != nil {
			return err
		}
		for _, e := range entries {
			ps := NewPositionStats(e.Stats.MaxValues)
			ps.Total = e.Stats.Total
			ps.ValueCounts = e.Stats.ValueCounts
			if ps.ValueCounts == nil {
				ps.ValueCounts = map[string]int{}
			}
			ps.TypeCounts = map[SegmentType]int{}
			for k, v := range e.Stats.TypeCounts {
				ps.TypeCounts[SegmentType(k)] = v
			}
			pos := Position{
				Host:    e.Position.Host,
				Scope:   PositionScope(e.Position.Scope),
				Locator: e.Position.Locator,
			}
			m.positionStats[pos] = ps
			m.positionKeys = append(m.positionKeys, pos)
		}
	}
	if msg, ok := raw["clusterer"]; ok {
		var cd clustererDumpShape
		if err := json.Unmarshal(msg, &cd); err != nil {
			return err
		}
		for key, c := range cd.Clusters {
			cluster := NewClusterWith(c.Key, c.Host, c.Scheme, c.Shape, m.maxValues)
			cluster.Count = c.Count
			for _, s := range c.Examples {
				iri, err := Parse(s)
				if err != nil {
					return err
				}
				cluster.Examples = append(cluster.Examples, iri)
				cluster.RegisterExampleKey(iri.Canonical())
			}
			cluster.SetSegmentCounts(c.SegmentCounts)
			if len(c.ParamStats) > 0 {
				for name, sd := range c.ParamStats {
					ps := NewPositionStats(sd.MaxValues)
					ps.Total = sd.Total
					if sd.ValueCounts != nil {
						ps.ValueCounts = sd.ValueCounts
					}
					ps.TypeCounts = map[SegmentType]int{}
					for k, v := range sd.TypeCounts {
						ps.TypeCounts[SegmentType(k)] = v
					}
					cluster.ParamStats[name] = ps
				}
			}
			m.clusters[key] = cluster
			m.clusterKeys = append(m.clusterKeys, key)
		}
	}
	return nil
}
