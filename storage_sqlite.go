//go:build sqlite

package iriq

import (
	"database/sql"
	"fmt"
	"strconv"

	_ "modernc.org/sqlite"
)

// HasSqlite reports whether this build includes the SQLite storage backend.
// Compiled-in when `-tags sqlite` is set.
const HasSqlite = true

const sqliteSchemaVersion = 3

const sqliteSchema = `
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);
CREATE TABLE IF NOT EXISTS host_counts (
  host  TEXT PRIMARY KEY,
  count INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS path_length_counts (
  length INTEGER PRIMARY KEY,
  count  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS raw_shape_counts (
  shape TEXT PRIMARY KEY,
  count INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS fingerprint_counts (
  shape TEXT PRIMARY KEY,
  count INTEGER NOT NULL
);
-- Position is (host, scope, locator). For scope='path' the locator is the
-- typed prefix; for scope='query' it's the param name. Today only 'path'
-- is observed here (query params live on the cluster_* tables) — scope is
-- in the schema so future commits can fold query positions in without
-- another migration.
CREATE TABLE IF NOT EXISTS position_stats (
  host    TEXT NOT NULL,
  scope   TEXT NOT NULL,
  locator TEXT NOT NULL,
  total   INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (host, scope, locator)
);
CREATE TABLE IF NOT EXISTS position_values (
  host    TEXT NOT NULL,
  scope   TEXT NOT NULL,
  locator TEXT NOT NULL,
  value   TEXT NOT NULL,
  count   INTEGER NOT NULL,
  PRIMARY KEY (host, scope, locator, value)
);
CREATE TABLE IF NOT EXISTS position_types (
  host    TEXT NOT NULL,
  scope   TEXT NOT NULL,
  locator TEXT NOT NULL,
  type    TEXT NOT NULL,
  count   INTEGER NOT NULL,
  PRIMARY KEY (host, scope, locator, type)
);
CREATE TABLE IF NOT EXISTS clusters (
  key    TEXT PRIMARY KEY,
  host   TEXT,
  scheme TEXT,
  shape  TEXT,
  count  INTEGER NOT NULL DEFAULT 0,
  ord    INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS cluster_examples (
  cluster_key TEXT NOT NULL,
  position    INTEGER NOT NULL,
  canonical   TEXT NOT NULL,
  PRIMARY KEY (cluster_key, position)
);
CREATE TABLE IF NOT EXISTS cluster_segments (
  cluster_key TEXT NOT NULL,
  position    INTEGER NOT NULL,
  value       TEXT NOT NULL,
  count       INTEGER NOT NULL,
  PRIMARY KEY (cluster_key, position, value)
);
CREATE TABLE IF NOT EXISTS cluster_params (
  cluster_key TEXT NOT NULL,
  name        TEXT NOT NULL,
  total       INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (cluster_key, name)
);
CREATE TABLE IF NOT EXISTS cluster_param_values (
  cluster_key TEXT NOT NULL,
  name        TEXT NOT NULL,
  value       TEXT NOT NULL,
  count       INTEGER NOT NULL,
  PRIMARY KEY (cluster_key, name, value)
);
CREATE TABLE IF NOT EXISTS cluster_param_types (
  cluster_key TEXT NOT NULL,
  name        TEXT NOT NULL,
  type        TEXT NOT NULL,
  count       INTEGER NOT NULL,
  PRIMARY KEY (cluster_key, name, type)
);
-- Source-IRI log. The materialized views above are derived from this log
-- via events + reducers. Corpus.Reinfer drops the views and replays the
-- log to rebuild them. id is monotonic so iteration order is observation
-- order.
CREATE TABLE IF NOT EXISTS observed_iris (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  canonical TEXT NOT NULL
);
`

// SqliteStorage is the incremental-write backend. Each observation is a
// short transaction of UPSERTs against a long-lived connection. WAL mode
// lets multiple processes observe against the same file concurrently.
type SqliteStorage struct {
	db         *sql.DB
	maxValues  int
	path       string
	classifier *SegmentClassifier
	tx         *sqliteTx // non-nil while inside Batch/Transaction
}

// We pin the pool to one connection so PRAGMA settings and the busy_timeout
// apply consistently. SQLite itself is single-writer; multiple connections
// from one process don't help (and complicate transaction handling).
//
// exec / query / queryRow direct everything through the active transaction
// when one is live, else through the connection.
type sqliteExec interface {
	Exec(query string, args ...interface{}) (sql.Result, error)
	Query(query string, args ...interface{}) (*sql.Rows, error)
	QueryRow(query string, args ...interface{}) *sql.Row
}

func (s *SqliteStorage) ex() sqliteExec {
	if s.tx != nil {
		return s.tx
	}
	return s.db
}

// Path returns the file path the SQLite database is bound to.
func (s *SqliteStorage) Path() string { return s.path }

// OpenSqliteStorage creates or opens a SQLite-backed corpus at path. Uses
// the DefaultClassifier for param-type classification; pass a custom one via
// OpenSqliteStorageWith.
func OpenSqliteStorage(path string, maxValues int) (*SqliteStorage, error) {
	return OpenSqliteStorageWith(path, maxValues, DefaultClassifier)
}

// OpenSqliteStorageWith lets callers (Corpus.OpenCorpus, tests) thread a
// specific classifier into the storage so ClusterParamStats classification
// matches the rest of the corpus.
func OpenSqliteStorageWith(path string, maxValues int, c *SegmentClassifier) (*SqliteStorage, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	// Pin to one connection so PRAGMAs and the implicit-transaction state
	// don't get partitioned across pooled connections.
	db.SetMaxOpenConns(1)
	if maxValues <= 0 {
		maxValues = DefaultMaxValuesPerPosition
	}
	if c == nil {
		c = DefaultClassifier
	}
	s := &SqliteStorage{db: db, maxValues: maxValues, path: path, classifier: c}
	if err := s.setup(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

func (s *SqliteStorage) setup() error {
	// busy_timeout MUST come first: other PRAGMAs (journal_mode in particular)
	// can themselves block on the write lock under concurrent open, and
	// without busy_timeout set they fail immediately with SQLITE_BUSY.
	if _, err := s.ex().Exec("PRAGMA busy_timeout = 30000"); err != nil {
		return err
	}
	if _, err := s.ex().Exec("PRAGMA journal_mode = WAL"); err != nil {
		return err
	}
	if _, err := s.ex().Exec("PRAGMA synchronous = NORMAL"); err != nil {
		return err
	}
	if _, err := s.ex().Exec(sqliteSchema); err != nil {
		return err
	}
	var existing sql.NullString
	if err := s.ex().QueryRow("SELECT value FROM meta WHERE key = 'schema_version'").Scan(&existing); err != nil && err != sql.ErrNoRows {
		return err
	}
	if !existing.Valid {
		if _, err := s.ex().Exec(
			"INSERT INTO meta (key, value) VALUES ('schema_version', ?)",
			strconv.Itoa(sqliteSchemaVersion),
		); err != nil {
			return err
		}
		if _, err := s.ex().Exec(
			"INSERT INTO meta (key, value) VALUES ('max_values_per_position', ?)",
			strconv.Itoa(s.maxValues),
		); err != nil {
			return err
		}
	} else {
		var stored sql.NullString
		_ = s.ex().QueryRow("SELECT value FROM meta WHERE key = 'max_values_per_position'").Scan(&stored)
		if stored.Valid {
			if n, err := strconv.Atoi(stored.String); err == nil && n > 0 {
				s.maxValues = n
			}
		}
	}
	return nil
}

func (s *SqliteStorage) MaxValues() int { return s.maxValues }

// Transaction runs fn inside a SQLite transaction. Nested calls share the
// outer transaction (no SAVEPOINTs needed for observe-time txns).
//
// Uses BEGIN IMMEDIATE so the write lock is acquired upfront (and
// busy_timeout applies). The default BEGIN DEFERRED would let multiple
// concurrent processes all enter the transaction and then race for the
// lock on the first write — leading to SQLITE_BUSY despite busy_timeout.
func (s *SqliteStorage) Transaction(fn func() error) error {
	if s.tx != nil {
		return fn()
	}
	if _, err := s.db.Exec("BEGIN IMMEDIATE"); err != nil {
		return err
	}
	tx := &sqliteTx{db: s.db}
	s.tx = tx
	defer func() { s.tx = nil }()
	if err := fn(); err != nil {
		_, _ = s.db.Exec("ROLLBACK")
		return err
	}
	_, err := s.db.Exec("COMMIT")
	return err
}

// sqliteTx is a minimal sql.Tx-shaped wrapper that proxies Exec/Query through
// the *sql.DB. Because we cap the pool at 1 connection, the parent BEGIN
// IMMEDIATE has the lock and the same connection serves all subsequent
// Exec/Query calls.
type sqliteTx struct {
	db *sql.DB
}

func (t *sqliteTx) Exec(q string, a ...interface{}) (sql.Result, error) {
	return t.db.Exec(q, a...)
}
func (t *sqliteTx) Query(q string, a ...interface{}) (*sql.Rows, error) {
	return t.db.Query(q, a...)
}
func (t *sqliteTx) QueryRow(q string, a ...interface{}) *sql.Row {
	return t.db.QueryRow(q, a...)
}

// Batch wraps many observations in a single transaction. SQLite UPSERTs are
// cheap CPU-wise but each fsync is expensive — batching turns O(observations)
// fsyncs into one.
func (s *SqliteStorage) Batch(fn func() error) error { return s.Transaction(fn) }

func (s *SqliteStorage) Flush() error { return nil }

func (s *SqliteStorage) Close() error {
	// Checkpoint + truncate the WAL so the .db-wal sidecar doesn't grow
	// unbounded across long-lived `iriq --corpus c.db` sessions.
	_, _ = s.db.Exec("PRAGMA wal_checkpoint(TRUNCATE)")
	return s.db.Close()
}

func (s *SqliteStorage) SaveTo(path string) error {
	// Export by materializing a Memory snapshot and writing JSON.
	mem := NewMemoryStorage(s.maxValues)
	mirrorIntoMemory(s, mem)
	return dumpMemoryToJSON(mem, path)
}

// --- Increments -------------------------------------------------------------

func (s *SqliteStorage) IncrementHost(host string) {
	// Empty host is meaningful for HostStrategyNone — see the comment on
	// MemoryStorage.IncrementHost.
	_, _ = s.ex().Exec(`
		INSERT INTO host_counts (host, count) VALUES (?, 1)
		ON CONFLICT(host) DO UPDATE SET count = count + 1
	`, host)
}

func (s *SqliteStorage) IncrementPathLength(length int) {
	_, _ = s.ex().Exec(`
		INSERT INTO path_length_counts (length, count) VALUES (?, 1)
		ON CONFLICT(length) DO UPDATE SET count = count + 1
	`, length)
}

func (s *SqliteStorage) IncrementRawShape(shape string)   { s.upsertShape("raw_shape_counts", shape) }
func (s *SqliteStorage) IncrementFingerprint(shape string) { s.upsertShape("fingerprint_counts", shape) }

func (s *SqliteStorage) upsertShape(table, shape string) {
	_, _ = s.ex().Exec(fmt.Sprintf(`
		INSERT INTO %s (shape, count) VALUES (?, 1)
		ON CONFLICT(shape) DO UPDATE SET count = count + 1
	`, table), shape)
}

func (s *SqliteStorage) ObservePosition(pos Position, value string, t SegmentType) {
	host, scope, locator := pos.Host, string(pos.Scope), pos.Locator
	_, _ = s.ex().Exec(`
		INSERT INTO position_stats (host, scope, locator, total) VALUES (?, ?, ?, 1)
		ON CONFLICT(host, scope, locator) DO UPDATE SET total = total + 1
	`, host, scope, locator)
	_, _ = s.ex().Exec(`
		INSERT INTO position_types (host, scope, locator, type, count) VALUES (?, ?, ?, ?, 1)
		ON CONFLICT(host, scope, locator, type) DO UPDATE SET count = count + 1
	`, host, scope, locator, string(t))

	// Value counts are capped — UPDATE first, INSERT only if under the cap.
	res, err := s.ex().Exec(
		"UPDATE position_values SET count = count + 1 WHERE host = ? AND scope = ? AND locator = ? AND value = ?",
		host, scope, locator, value,
	)
	// err != nil ⇒ res may be nil; treat the update as a no-op (zero rows
	// affected) so the INSERT path runs. If the INSERT also fails, the outer
	// transaction will roll back.
	if affected := rowsAffected(res, err); affected == 0 {
		var card int
		_ = s.ex().QueryRow(
			"SELECT COUNT(*) FROM position_values WHERE host = ? AND scope = ? AND locator = ?",
			host, scope, locator,
		).Scan(&card)
		if card < s.maxValues {
			_, _ = s.ex().Exec(
				"INSERT INTO position_values (host, scope, locator, value, count) VALUES (?, ?, ?, ?, 1)",
				host, scope, locator, value,
			)
		}
	}
}

// RecordObservation appends a canonical IRI to the source log. Called by
// Corpus.Observe inside the same transaction as the event reducers, so the
// log and views stay consistent.
func (s *SqliteStorage) RecordObservation(canonical string) {
	_, _ = s.ex().Exec("INSERT INTO observed_iris (canonical) VALUES (?)", canonical)
}

func (s *SqliteStorage) EachObservedIRI(fn func(canonical string)) {
	rows, err := s.ex().Query("SELECT canonical FROM observed_iris ORDER BY id")
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err == nil {
			fn(c)
		}
	}
}

func (s *SqliteStorage) ObservedIRICount() int {
	var n int
	_ = s.ex().QueryRow("SELECT COUNT(*) FROM observed_iris").Scan(&n)
	return n
}

// ClearMaterializedViews drops every derived view without touching the
// source-IRI log. Corpus.Reinfer calls this before replaying the log.
func (s *SqliteStorage) ClearMaterializedViews() {
	stmts := []string{
		"DELETE FROM host_counts",
		"DELETE FROM path_length_counts",
		"DELETE FROM raw_shape_counts",
		"DELETE FROM fingerprint_counts",
		"DELETE FROM position_stats",
		"DELETE FROM position_values",
		"DELETE FROM position_types",
		"DELETE FROM clusters",
		"DELETE FROM cluster_examples",
		"DELETE FROM cluster_segments",
		"DELETE FROM cluster_params",
		"DELETE FROM cluster_param_values",
		"DELETE FROM cluster_param_types",
	}
	for _, q := range stmts {
		_, _ = s.ex().Exec(q)
	}
}

func (s *SqliteStorage) AddToCluster(key, host, scheme, shape string, iri *Identifier) *Cluster {
	_, _ = s.ex().Exec(`
		INSERT INTO clusters (key, host, scheme, shape, count, ord)
		VALUES (?, ?, ?, ?, 1, (SELECT COALESCE(MAX(ord), 0) + 1 FROM clusters))
		ON CONFLICT(key) DO UPDATE SET count = count + 1
	`, key, host, scheme, shape)

	var examplesCount int
	_ = s.ex().QueryRow("SELECT COUNT(*) FROM cluster_examples WHERE cluster_key = ?", key).Scan(&examplesCount)
	if examplesCount < MaxClusterExamples {
		_, _ = s.ex().Exec(
			"INSERT INTO cluster_examples (cluster_key, position, canonical) VALUES (?, ?, ?)",
			key, examplesCount, iri.Canonical(),
		)
	}

	for i, seg := range iri.PathSegments {
		_, _ = s.ex().Exec(`
			INSERT INTO cluster_segments (cluster_key, position, value, count) VALUES (?, ?, ?, 1)
			ON CONFLICT(cluster_key, position, value) DO UPDATE SET count = count + 1
		`, key, i, seg)
	}

	// Per-param stats — presence + value cardinality + type.
	if iri.QueryParams != nil {
		classifier := s.classifier
		if classifier == nil {
			classifier = DefaultClassifier
		}
		for _, name := range iri.QueryParams.Keys() {
			v, _ := iri.QueryParams.Get(name)
			t := classifier.Classify(v)

			_, _ = s.ex().Exec(`
				INSERT INTO cluster_params (cluster_key, name, total) VALUES (?, ?, 1)
				ON CONFLICT(cluster_key, name) DO UPDATE SET total = total + 1
			`, key, name)
			_, _ = s.ex().Exec(`
				INSERT INTO cluster_param_types (cluster_key, name, type, count) VALUES (?, ?, ?, 1)
				ON CONFLICT(cluster_key, name, type) DO UPDATE SET count = count + 1
			`, key, name, string(t))
			res, err := s.ex().Exec(
				"UPDATE cluster_param_values SET count = count + 1 WHERE cluster_key = ? AND name = ? AND value = ?",
				key, name, v,
			)
			if affected := rowsAffected(res, err); affected == 0 {
				var card int
				_ = s.ex().QueryRow(
					"SELECT COUNT(*) FROM cluster_param_values WHERE cluster_key = ? AND name = ?", key, name,
				).Scan(&card)
				if card < s.maxValues {
					_, _ = s.ex().Exec(
						"INSERT INTO cluster_param_values (cluster_key, name, value, count) VALUES (?, ?, ?, 1)",
						key, name, v,
					)
				}
			}
		}
	}

	// Return a lightweight cluster ref — full Examples / SegmentCounts /
	// ParamStats are materialized lazily via Storage.Clusters() /
	// Storage.ClusterFor(). Skipping loadCluster here removes 3+ SELECTs per
	// observation in the hot batch path.
	var count int
	_ = s.ex().QueryRow("SELECT count FROM clusters WHERE key = ?", key).Scan(&count)
	c := NewCluster(key, host, scheme, shape)
	c.Count = count
	return c
}

// ClusterFor is the lookup used by Corpus.Normalize / ParamsFor. Materializes
// examples + segment counts + param stats.
func (s *SqliteStorage) ClusterFor(key string) *Cluster { return s.loadCluster(key) }

// --- Reads ------------------------------------------------------------------

func (s *SqliteStorage) HostCounts() map[string]int     { return s.countsHash("host_counts", "host") }
func (s *SqliteStorage) RawShapeCounts() map[string]int { return s.countsHash("raw_shape_counts", "shape") }
func (s *SqliteStorage) FingerprintCounts() map[string]int {
	return s.countsHash("fingerprint_counts", "shape")
}

func (s *SqliteStorage) PathLengthCounts() map[int]int {
	out := map[int]int{}
	rows, err := s.ex().Query("SELECT length, count FROM path_length_counts")
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var k, v int
		if err := rows.Scan(&k, &v); err == nil {
			out[k] = v
		}
	}
	return out
}

func (s *SqliteStorage) countsHash(table, keyCol string) map[string]int {
	out := map[string]int{}
	rows, err := s.ex().Query(fmt.Sprintf("SELECT %s, count FROM %s", keyCol, table))
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var k string
		var v int
		if err := rows.Scan(&k, &v); err == nil {
			out[k] = v
		}
	}
	return out
}

func (s *SqliteStorage) PositionStatsFor(pos Position) *PositionStats {
	host, scope, locator := pos.Host, string(pos.Scope), pos.Locator
	var total int
	if err := s.ex().QueryRow(
		"SELECT total FROM position_stats WHERE host = ? AND scope = ? AND locator = ?",
		host, scope, locator,
	).Scan(&total); err != nil {
		return nil
	}

	ps := NewPositionStats(s.maxValues)
	ps.Total = total

	rows, err := s.ex().Query(
		"SELECT value, count FROM position_values WHERE host = ? AND scope = ? AND locator = ?",
		host, scope, locator,
	)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var v string
			var c int
			if err := rows.Scan(&v, &c); err == nil {
				ps.ValueCounts[v] = c
			}
		}
	}

	rows2, err := s.ex().Query(
		"SELECT type, count FROM position_types WHERE host = ? AND scope = ? AND locator = ?",
		host, scope, locator,
	)
	if err == nil {
		defer rows2.Close()
		for rows2.Next() {
			var t string
			var c int
			if err := rows2.Scan(&t, &c); err == nil {
				ps.TypeCounts[SegmentType(t)] = c
			}
		}
	}
	return ps
}

func (s *SqliteStorage) EachPositionStats(fn func(pos Position, stats *PositionStats)) {
	rows, err := s.ex().Query("SELECT host, scope, locator FROM position_stats ORDER BY ROWID")
	if err != nil {
		return
	}
	var keys []Position
	for rows.Next() {
		var host, scope, locator string
		if err := rows.Scan(&host, &scope, &locator); err == nil {
			keys = append(keys, Position{Host: host, Scope: PositionScope(scope), Locator: locator})
		}
	}
	rows.Close()
	for _, k := range keys {
		fn(k, s.PositionStatsFor(k))
	}
}

func (s *SqliteStorage) Clusters() []*Cluster {
	rows, err := s.ex().Query("SELECT key FROM clusters ORDER BY ord")
	if err != nil {
		return nil
	}
	var keys []string
	for rows.Next() {
		var k string
		if err := rows.Scan(&k); err == nil {
			keys = append(keys, k)
		}
	}
	rows.Close()
	out := make([]*Cluster, 0, len(keys))
	for _, k := range keys {
		if c := s.loadCluster(k); c != nil {
			out = append(out, c)
		}
	}
	return out
}

func (s *SqliteStorage) ClusterSize() int {
	var n int
	_ = s.ex().QueryRow("SELECT COUNT(*) FROM clusters").Scan(&n)
	return n
}

func (s *SqliteStorage) loadCluster(key string) *Cluster {
	var c Cluster
	c.Key = key
	if err := s.ex().QueryRow(
		"SELECT host, scheme, shape, count FROM clusters WHERE key = ?", key,
	).Scan(&c.Host, &c.Scheme, &c.Shape, &c.Count); err != nil {
		return nil
	}

	// Each rows query gets its own scoped closure so `defer Close()` releases
	// the (singleton) connection at block-end rather than at function-end —
	// otherwise the next Query in this same function would block forever on
	// the pinned connection (SetMaxOpenConns(1)) if a prior loop short-
	// circuited before draining Rows.
	s.scanRows(
		"SELECT canonical FROM cluster_examples WHERE cluster_key = ? ORDER BY position",
		[]interface{}{key},
		func(rows *sql.Rows) {
			var canonical string
			if err := rows.Scan(&canonical); err != nil {
				return
			}
			if iri, perr := Parse(canonical); perr == nil {
				c.Examples = append(c.Examples, iri)
				c.RegisterExampleKey(iri.Canonical())
			}
		},
	)

	var segCounts []map[string]int
	s.scanRows(
		"SELECT position, value, count FROM cluster_segments WHERE cluster_key = ? ORDER BY position",
		[]interface{}{key},
		func(rows *sql.Rows) {
			var pos, count int
			var value string
			if err := rows.Scan(&pos, &value, &count); err != nil {
				return
			}
			for len(segCounts) <= pos {
				segCounts = append(segCounts, map[string]int{})
			}
			segCounts[pos][value] = count
		},
	)
	c.SetSegmentCounts(segCounts)

	c.ParamStats = map[string]*PositionStats{}
	s.scanRows(
		"SELECT name, total FROM cluster_params WHERE cluster_key = ?",
		[]interface{}{key},
		func(rows *sql.Rows) {
			var name string
			var total int
			if err := rows.Scan(&name, &total); err != nil {
				return
			}
			stats := NewPositionStats(s.maxValues)
			stats.Total = total
			c.ParamStats[name] = stats
		},
	)
	s.scanRows(
		"SELECT name, value, count FROM cluster_param_values WHERE cluster_key = ?",
		[]interface{}{key},
		func(rows *sql.Rows) {
			var name, value string
			var count int
			if err := rows.Scan(&name, &value, &count); err != nil {
				return
			}
			if stats, ok := c.ParamStats[name]; ok {
				stats.ValueCounts[value] = count
			}
		},
	)
	s.scanRows(
		"SELECT name, type, count FROM cluster_param_types WHERE cluster_key = ?",
		[]interface{}{key},
		func(rows *sql.Rows) {
			var name, t string
			var count int
			if err := rows.Scan(&name, &t, &count); err != nil {
				return
			}
			if stats, ok := c.ParamStats[name]; ok {
				stats.TypeCounts[SegmentType(t)] = count
			}
		},
	)
	return &c
}

// scanRows runs query, defers Close at block end, calls onRow for each row.
// Keeps the (singleton) SQLite connection-release scope tight so adjacent
// queries in the same function don't deadlock on each other.
func (s *SqliteStorage) scanRows(query string, args []interface{}, onRow func(*sql.Rows)) {
	rows, err := s.ex().Query(query, args...)
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		onRow(rows)
	}
	// Discarded — surfacing it would require changing the function signature
	// and propagating partial-failure semantics through every caller. Worth
	// revisiting if a corrupted cluster_param table starts showing up in
	// practice.
	_ = rows.Err()
}

// mirrorIntoMemory walks every row of an SQLite store and replays the data
// into a fresh MemoryStorage. Used for SaveTo (JSON export).
func mirrorIntoMemory(src Storage, dst *MemoryStorage) {
	for k, v := range src.HostCounts() {
		dst.hostCounts[k] = v
	}
	for k, v := range src.PathLengthCounts() {
		dst.pathLengthCounts[k] = v
	}
	for k, v := range src.RawShapeCounts() {
		dst.rawShapeCounts[k] = v
	}
	for k, v := range src.FingerprintCounts() {
		dst.fingerprintCounts[k] = v
	}
	src.EachPositionStats(func(pos Position, stats *PositionStats) {
		dst.positionStats[pos] = stats
		dst.positionKeys = append(dst.positionKeys, pos)
	})
	for _, c := range src.Clusters() {
		dst.clusters[c.Key] = c
		dst.clusterKeys = append(dst.clusterKeys, c.Key)
	}
}

// rowsAffected safely extracts the affected-row count from an Exec result,
// guarding against a nil sql.Result returned together with an error (the
// modernc.org/sqlite driver does this on some prepare failures). Treats
// any error as "zero rows", letting the caller's INSERT fallback run.
func rowsAffected(res sql.Result, err error) int64 {
	if err != nil || res == nil {
		return 0
	}
	n, ierr := res.RowsAffected()
	if ierr != nil {
		return 0
	}
	return n
}
