package iriq

import (
	"path/filepath"
	"strings"
)

// Storage is the persistence layer behind a Corpus. Two backends ship:
// MemoryStorage (in-memory, optionally wrapped with JSON load/save) and
// SqliteStorage (incremental UPSERTs against a SQLite file).
//
// The contract is intentionally narrow — the Corpus owns all classification
// logic, while Storage owns where the counters live and how observations
// reach disk.
type Storage interface {
	// Increments — every observe() turns into a fixed handful of these.
	IncrementHost(host string)
	IncrementPathLength(length int)
	IncrementRawShape(shape string)
	IncrementFingerprint(shape string)
	ObservePosition(host, prefix, value string, t SegmentType)
	AddToCluster(key, host, scheme, shape string, iri *Identifier) *Cluster

	// Reads — materialize what the caller asks for, not the whole corpus.
	HostCounts() map[string]int
	PathLengthCounts() map[int]int
	RawShapeCounts() map[string]int
	FingerprintCounts() map[string]int
	PositionStatsFor(host, prefix string) *PositionStats
	EachPositionStats(func(host, prefix string, stats *PositionStats))
	Clusters() []*Cluster
	ClusterSize() int

	// Lifecycle.
	MaxValues() int
	Transaction(func() error) error
	// Batch wraps many observations in a single transaction — SQLite turns
	// O(observations) fsyncs into one; Memory/JSON are no-ops.
	Batch(func() error) error
	Flush() error
	Close() error

	// SaveTo writes the corpus to disk at the requested location. For the
	// JSON backend that's the canonical save path; for SQLite (where writes
	// are already incremental) it's effectively an export.
	SaveTo(path string) error
}

// OpenStorage opens (or creates) a Storage at path, picking the backend by
// file extension. Pass "" for an in-memory backend.
func OpenStorage(path string, maxValues int) (Storage, error) {
	if path == "" {
		return NewMemoryStorage(maxValues), nil
	}
	switch strings.ToLower(filepath.Ext(path)) {
	case ".db", ".sqlite", ".sqlite3":
		return OpenSqliteStorage(path, maxValues)
	default:
		return OpenJSONStorage(path, maxValues)
	}
}
