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
	ObservePosition(pos Position, value string, t SegmentType)
	AddToCluster(key, host, scheme, shape string, iri *Identifier) *Cluster

	// Reads — materialize what the caller asks for, not the whole corpus.
	HostCounts() map[string]int
	PathLengthCounts() map[int]int
	RawShapeCounts() map[string]int
	FingerprintCounts() map[string]int
	PositionStatsFor(pos Position) *PositionStats
	EachPositionStats(func(pos Position, stats *PositionStats))
	Clusters() []*Cluster
	ClusterFor(key string) *Cluster
	ClusterSize() int

	// Source-IRI log. The materialized views above are derived from this
	// log; Corpus.Reinfer drops the views and replays the log to rebuild
	// them. RecordObservation appends; EachObservedIRI iterates;
	// ClearMaterializedViews drops the views without touching the log.
	RecordObservation(canonical string)
	EachObservedIRI(func(canonical string))
	ObservedIRICount() int
	ClearMaterializedViews()

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
	return OpenStorageWith(path, maxValues, DefaultClassifier)
}

// OpenStorageWith lets callers thread a specific classifier into the backend
// so cluster.ParamStats type counts use the same classifier as the corpus.
func OpenStorageWith(path string, maxValues int, c *SegmentClassifier) (Storage, error) {
	if path == "" {
		return NewMemoryStorageWith(maxValues, c), nil
	}
	switch strings.ToLower(filepath.Ext(path)) {
	case ".db", ".sqlite", ".sqlite3":
		return OpenSqliteStorageWith(path, maxValues, c)
	default:
		return OpenJSONStorageWith(path, maxValues, c)
	}
}
