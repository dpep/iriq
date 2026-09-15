// SQLite-backed corpus storage. Mirrors Ruby's storage/sqlite.rb schema
// byte-for-byte so a corpus created by either runtime opens cleanly in
// the other.
//
// Lock discipline: writers take `&mut self` and reach the connection through
// `Mutex::get_mut`, so they never lock; readers lock through `conn()` and
// never call back into user code while holding the guard.

use crate::classifier::{segment_type_from_name, SegmentType, DEFAULT_CLASSIFIER};
use crate::cluster::{Cluster, MAX_CLUSTER_EXAMPLES};
use crate::errors::{Error, Result};
use crate::identifier::Identifier;
use crate::parser::parse;
use crate::position::{Position, PositionScope};
use crate::position_stats::{PositionStats, DEFAULT_MAX_VALUES_PER_POSITION};
use crate::storage::{PositionEvidence, Storage};
use crate::storage_json::rebuild_numeric_stats;
use crate::storage_memory::MemoryStorage;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};

const SCHEMA: &str = include_str!("./sqlite_schema.sql");
const SCHEMA_VERSION: i64 = 4;

pub struct SqliteStorage {
    conn: Mutex<Connection>,
    max_values: usize,
    path: PathBuf,
    /// Batches open on this connection; the first is the transaction.
    depth: usize,
    /// Tracked values per position, counted inside a batch so each new value
    /// needn't re-count them. Exact only while this connection holds the
    /// write lock and, across batches, while `counts_version` still matches.
    value_counts: HashMap<Position, usize>,
    /// `PRAGMA data_version` as of the batch that filled `value_counts`; it
    /// changes when any other connection commits.
    counts_version: Option<i64>,
}

impl SqliteStorage {
    pub fn open(path: &Path, max_values: usize) -> Result<Self> {
        let rs_err = |e| Error::sqlite(path, e);
        let conn = Connection::open(path).map_err(rs_err)?;
        // PRAGMAs first (busy_timeout before journal_mode).
        conn.execute_batch("PRAGMA busy_timeout = 30000;")
            .map_err(rs_err)?;
        // Before anything writes: a newer build's corpus must be left as it is.
        if let Some(stored) = stored_schema_version(&conn).map_err(rs_err)? {
            if stored > SCHEMA_VERSION {
                return Err(Error::unsupported(
                    path,
                    format!(
                        "schema version {stored} is newer than this iriq supports \
                         ({SCHEMA_VERSION}); upgrade iriq"
                    ),
                ));
            }
        }
        enable_wal(&conn, path)?;
        conn.execute_batch("PRAGMA synchronous = NORMAL;")
            .map_err(rs_err)?;
        conn.execute_batch(SCHEMA).map_err(rs_err)?;

        let max_values = if max_values == 0 {
            DEFAULT_MAX_VALUES_PER_POSITION
        } else {
            max_values
        };
        let existing: Option<String> = conn
            .query_row(
                "SELECT value FROM meta WHERE key = 'schema_version'",
                [],
                |r| r.get(0),
            )
            .optional()
            .map_err(rs_err)?;
        let mut max_values = max_values;
        if existing.is_none() {
            // OR IGNORE: two processes can race to initialize a fresh corpus
            // concurrently — both read schema_version as None, and the
            // loser's INSERT must not blow up on the PRIMARY KEY.
            conn.execute(
                "INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', ?)",
                params![SCHEMA_VERSION.to_string()],
            )
            .map_err(rs_err)?;
            conn.execute(
                "INSERT OR IGNORE INTO meta (key, value) VALUES ('max_values_per_position', ?)",
                params![max_values.to_string()],
            )
            .map_err(rs_err)?;
        } else {
            let stored: Option<String> = conn
                .query_row(
                    "SELECT value FROM meta WHERE key = 'max_values_per_position'",
                    [],
                    |r| r.get(0),
                )
                .optional()
                .map_err(rs_err)?;
            if let Some(s) = stored {
                if let Ok(n) = s.parse::<usize>() {
                    if n > 0 {
                        max_values = n;
                    }
                }
            }
        }

        Ok(SqliteStorage {
            conn: Mutex::new(conn),
            max_values,
            path: path.to_path_buf(),
            depth: 0,
            value_counts: HashMap::new(),
            counts_version: None,
        })
    }

    /// The connection for a read. Poison is ignored: SQLite, not the Rust
    /// guard, owns the data's consistency.
    fn conn(&self) -> MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Run a read, naming the corpus in any failure.
    fn read<T>(&self, f: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> Result<T> {
        f(&self.conn()).map_err(|e| Error::sqlite(&self.path, e))
    }

    fn position_stats_for(&self, pos: &Position) -> Result<Option<PositionStats>> {
        self.read(|c| {
            let key = params![pos.host, pos.scope.as_str(), pos.locator];
            let Some(total) = c
                .prepare_cached(
                    "SELECT total FROM position_stats WHERE host = ? AND scope = ? AND locator = ?",
                )?
                .query_row(key, |r| r.get::<_, i64>(0))
                .optional()?
            else {
                return Ok(None);
            };
            let mut ps = PositionStats::new(self.max_values);
            ps.total = total as usize;
            ps.value_counts = c
                .prepare_cached(
                    "SELECT value, count FROM position_values WHERE host = ? AND scope = ? AND locator = ?",
                )?
                .query_map(key, |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as usize))
                })?
                .collect::<rusqlite::Result<_>>()?;
            ps.type_counts = c
                .prepare_cached(
                    "SELECT type, count FROM position_types WHERE host = ? AND scope = ? AND locator = ?",
                )?
                .query_map(key, |r| {
                    Ok((
                        segment_type_from_name(&r.get::<_, String>(0)?),
                        r.get::<_, i64>(1)? as usize,
                    ))
                })?
                .collect::<rusqlite::Result<_>>()?;
            rebuild_numeric_stats(&mut ps);
            Ok(Some(ps))
        })
    }
}

/// The schema version a corpus file records, if it records one yet. A fresh
/// file has no `meta` table, so check for it rather than query and fail.
fn stored_schema_version(conn: &Connection) -> rusqlite::Result<Option<i64>> {
    let has_meta: bool = conn.query_row(
        "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta')",
        [],
        |r| r.get(0),
    )?;
    if !has_meta {
        return Ok(None);
    }
    let stored: Option<String> = conn
        .query_row(
            "SELECT value FROM meta WHERE key = 'schema_version'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    Ok(stored.and_then(|v| v.parse().ok()))
}

/// Converting a rollback-mode database to WAL takes an exclusive lock, and
/// SQLite does NOT consult the busy handler for that lock — so concurrent
/// first-opens of a fresh corpus can fail with SQLITE_BUSY even with
/// busy_timeout set. WAL is a persistent database property: retry briefly —
/// either this connection wins the conversion or another process already
/// converted the file.
fn enable_wal(conn: &Connection, path: &Path) -> Result<()> {
    let mut attempts = 0;
    loop {
        match conn.execute_batch("PRAGMA journal_mode = WAL;") {
            Ok(()) => return Ok(()),
            Err(rusqlite::Error::SqliteFailure(e, _))
                if attempts < 100
                    && matches!(
                        e.code,
                        rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked
                    ) =>
            {
                attempts += 1;
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            Err(e) => return Err(Error::sqlite(path, e)),
        }
    }
}

impl Storage for SqliteStorage {
    fn max_values(&self) -> usize {
        self.max_values
    }

    fn increment_host(&mut self, host: &str) -> Result<()> {
        let c = self.conn.get_mut().unwrap_or_else(PoisonError::into_inner);
        c.prepare_cached(
            "INSERT INTO host_counts (host, count) VALUES (?, 1) ON CONFLICT(host) DO UPDATE SET count = count + 1",
        )
        .and_then(|mut s| s.execute(params![host]))
        .map_err(|e| Error::sqlite(&self.path, e))?;
        Ok(())
    }
    fn increment_path_length(&mut self, length: usize) -> Result<()> {
        let c = self.conn.get_mut().unwrap_or_else(PoisonError::into_inner);
        c.prepare_cached(
            "INSERT INTO path_length_counts (length, count) VALUES (?, 1) ON CONFLICT(length) DO UPDATE SET count = count + 1",
        )
        .and_then(|mut s| s.execute(params![length as i64]))
        .map_err(|e| Error::sqlite(&self.path, e))?;
        Ok(())
    }
    fn increment_raw_shape(&mut self, shape: &str) -> Result<()> {
        let c = self.conn.get_mut().unwrap_or_else(PoisonError::into_inner);
        c.prepare_cached(
            "INSERT INTO raw_shape_counts (shape, count) VALUES (?, 1) ON CONFLICT(shape) DO UPDATE SET count = count + 1",
        )
        .and_then(|mut s| s.execute(params![shape]))
        .map_err(|e| Error::sqlite(&self.path, e))?;
        Ok(())
    }
    fn increment_fingerprint(&mut self, shape: &str) -> Result<()> {
        let c = self.conn.get_mut().unwrap_or_else(PoisonError::into_inner);
        c.prepare_cached(
            "INSERT INTO fingerprint_counts (shape, count) VALUES (?, 1) ON CONFLICT(shape) DO UPDATE SET count = count + 1",
        )
        .and_then(|mut s| s.execute(params![shape]))
        .map_err(|e| Error::sqlite(&self.path, e))?;
        Ok(())
    }

    fn observe_position(&mut self, pos: &Position, value: &str, t: SegmentType) -> Result<()> {
        let c = self.conn.get_mut().unwrap_or_else(PoisonError::into_inner);
        let err = |e| Error::sqlite(&self.path, e);
        let scope = pos.scope.as_str();
        c.prepare_cached(
            "INSERT INTO position_stats (host, scope, locator, total) VALUES (?, ?, ?, 1) \
             ON CONFLICT(host, scope, locator) DO UPDATE SET total = total + 1",
        )
        .and_then(|mut s| s.execute(params![pos.host, scope, pos.locator]))
        .map_err(err)?;
        c.prepare_cached(
            "INSERT INTO position_types (host, scope, locator, type, count) VALUES (?, ?, ?, ?, 1) \
             ON CONFLICT(host, scope, locator, type) DO UPDATE SET count = count + 1",
        )
        .and_then(|mut s| s.execute(params![pos.host, scope, pos.locator, t.as_str()]))
        .map_err(err)?;
        let updated = c
            .prepare_cached(
                "UPDATE position_values SET count = count + 1 WHERE host = ? AND scope = ? AND locator = ? AND value = ?",
            )
            .and_then(|mut s| s.execute(params![pos.host, scope, pos.locator, value]))
            .map_err(err)?;
        if updated == 0 {
            let remembered = self.value_counts.get(pos).filter(|_| self.depth > 0);
            let mut card = match remembered {
                Some(&n) => n,
                None => c
                    .prepare_cached(
                        "SELECT COUNT(*) FROM position_values WHERE host = ? AND scope = ? AND locator = ?",
                    )
                    .and_then(|mut s| {
                        s.query_row(params![pos.host, scope, pos.locator], |r| {
                            r.get::<_, i64>(0)
                        })
                    })
                    .map_err(err)? as usize,
            };
            if card < self.max_values {
                c.prepare_cached(
                    "INSERT INTO position_values (host, scope, locator, value, count) VALUES (?, ?, ?, ?, 1)",
                )
                .and_then(|mut s| s.execute(params![pos.host, scope, pos.locator, value]))
                .map_err(err)?;
                card += 1;
            }
            if self.depth > 0 {
                self.value_counts.insert(pos.clone(), card);
            }
        }
        Ok(())
    }

    fn add_to_cluster(
        &mut self,
        key: &str,
        host: &str,
        scheme: &str,
        shape: &str,
        iri: &Identifier,
    ) -> Result<()> {
        let c = self.conn.get_mut().unwrap_or_else(PoisonError::into_inner);
        let err = |e| Error::sqlite(&self.path, e);
        // The next ord scans every cluster (ord has no index), so only a new
        // cluster pays for it; ON CONFLICT covers a writer that inserted it since.
        let bumped = c
            .prepare_cached("UPDATE clusters SET count = count + 1 WHERE key = ?")
            .and_then(|mut s| s.execute(params![key]))
            .map_err(err)?;
        if bumped == 0 {
            c.prepare_cached(
                "INSERT INTO clusters (key, host, scheme, shape, count, ord) \
                 VALUES (?, ?, ?, ?, 1, (SELECT COALESCE(MAX(ord), 0) + 1 FROM clusters)) \
                 ON CONFLICT(key) DO UPDATE SET count = count + 1",
            )
            .and_then(|mut s| s.execute(params![key, host, scheme, shape]))
            .map_err(err)?;
        }

        let examples_count: i64 = c
            .prepare_cached("SELECT COUNT(*) FROM cluster_examples WHERE cluster_key = ?")
            .and_then(|mut s| s.query_row(params![key], |r| r.get(0)))
            .map_err(err)?;
        if (examples_count as usize) < MAX_CLUSTER_EXAMPLES {
            let canon = iri.canonical();
            let exists: i64 = c
                .prepare_cached(
                    "SELECT COUNT(*) FROM cluster_examples WHERE cluster_key = ? AND canonical = ?",
                )
                .and_then(|mut s| s.query_row(params![key, canon], |r| r.get(0)))
                .map_err(err)?;
            if exists == 0 {
                c.prepare_cached(
                    "INSERT INTO cluster_examples (cluster_key, position, canonical) VALUES (?, ?, ?)",
                )
                .and_then(|mut s| s.execute(params![key, examples_count, canon]))
                .map_err(err)?;
            }
        }

        {
            let mut stmt = c
                .prepare_cached(
                    "INSERT INTO cluster_segments (cluster_key, position, value, count) VALUES (?, ?, ?, 1) \
                     ON CONFLICT(cluster_key, position, value) DO UPDATE SET count = count + 1",
                )
                .map_err(err)?;
            for (i, seg) in iri.path_segments.iter().enumerate() {
                stmt.execute(params![key, i as i64, seg]).map_err(err)?;
            }
        }

        let classifier = &DEFAULT_CLASSIFIER;
        for (name, v) in iri.query_params.iter() {
            let t = classifier.classify(v);
            c.prepare_cached(
                "INSERT INTO cluster_params (cluster_key, name, total) VALUES (?, ?, 1) \
                 ON CONFLICT(cluster_key, name) DO UPDATE SET total = total + 1",
            )
            .and_then(|mut s| s.execute(params![key, name]))
            .map_err(err)?;
            c.prepare_cached(
                "INSERT INTO cluster_param_types (cluster_key, name, type, count) VALUES (?, ?, ?, 1) \
                 ON CONFLICT(cluster_key, name, type) DO UPDATE SET count = count + 1",
            )
            .and_then(|mut s| s.execute(params![key, name, t.as_str()]))
            .map_err(err)?;
            let updated = c
                .prepare_cached(
                    "UPDATE cluster_param_values SET count = count + 1 WHERE cluster_key = ? AND name = ? AND value = ?",
                )
                .and_then(|mut s| s.execute(params![key, name, v]))
                .map_err(err)?;
            if updated == 0 {
                let card: i64 = c
                    .prepare_cached(
                        "SELECT COUNT(*) FROM cluster_param_values WHERE cluster_key = ? AND name = ?",
                    )
                    .and_then(|mut s| s.query_row(params![key, name], |r| r.get(0)))
                    .map_err(err)?;
                if (card as usize) < self.max_values {
                    c.prepare_cached(
                        "INSERT INTO cluster_param_values (cluster_key, name, value, count) VALUES (?, ?, ?, 1)",
                    )
                    .and_then(|mut s| s.execute(params![key, name, v]))
                    .map_err(err)?;
                }
            }
        }
        Ok(())
    }

    fn host_counts(&self) -> Result<HashMap<String, usize>> {
        self.read(|c| counts_hash(c, "host_counts", "host"))
    }
    fn path_length_counts(&self) -> Result<HashMap<usize, usize>> {
        self.read(|c| {
            let mut stmt = c.prepare("SELECT length, count FROM path_length_counts")?;
            let rows = stmt.query_map([], |r| {
                Ok((r.get::<_, i64>(0)? as usize, r.get::<_, i64>(1)? as usize))
            })?;
            rows.collect()
        })
    }
    fn raw_shape_counts(&self) -> Result<HashMap<String, usize>> {
        self.read(|c| counts_hash(c, "raw_shape_counts", "shape"))
    }
    fn fingerprint_counts(&self) -> Result<HashMap<String, usize>> {
        self.read(|c| counts_hash(c, "fingerprint_counts", "shape"))
    }

    fn each_position_stats(&self, f: &mut dyn FnMut(&Position, &PositionStats)) -> Result<()> {
        let keys: Vec<Position> = self.read(|c| {
            let mut stmt =
                c.prepare("SELECT host, scope, locator FROM position_stats ORDER BY ROWID")?;
            let rows = stmt.query_map([], |r| {
                Ok(Position {
                    host: r.get(0)?,
                    scope: if r.get::<_, String>(1)? == "query" {
                        PositionScope::Query
                    } else {
                        PositionScope::Path
                    },
                    locator: r.get(2)?,
                })
            })?;
            rows.collect()
        })?;
        for k in keys {
            if let Some(stats) = self.position_stats_for(&k)? {
                f(&k, &stats);
            }
        }
        Ok(())
    }

    fn clusters(&self) -> Result<Vec<Cluster>> {
        self.read(|c| {
            let mut stmt = c.prepare("SELECT key FROM clusters ORDER BY ord")?;
            let keys = stmt
                .query_map([], |r| r.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            let mut out = Vec::with_capacity(keys.len());
            for key in &keys {
                out.extend(load_cluster(c, key, self.max_values)?);
            }
            Ok(out)
        })
    }
    fn cluster_for(&self, key: &str) -> Result<Option<Cluster>> {
        self.read(|c| load_cluster(c, key, self.max_values))
    }
    fn cluster_size(&self) -> Result<usize> {
        self.read(|c| c.query_row("SELECT COUNT(*) FROM clusters", [], |r| r.get::<_, i64>(0)))
            .map(|n| n as usize)
    }

    fn position_evidence(&self, pos: &Position, value: &str) -> Result<Option<PositionEvidence>> {
        let c = self.conn();
        let key = params![pos.host, pos.scope.as_str(), pos.locator];
        let read = || -> rusqlite::Result<Option<PositionEvidence>> {
            let Some(total) = c
                .prepare_cached(
                    "SELECT total FROM position_stats WHERE host = ? AND scope = ? AND locator = ?",
                )?
                .query_row(key, |r| r.get::<_, i64>(0))
                .optional()?
            else {
                return Ok(None);
            };
            let type_counts = c
                .prepare_cached(
                    "SELECT type, count FROM position_types WHERE host = ? AND scope = ? AND locator = ?",
                )?
                .query_map(key, |r| {
                    Ok((
                        segment_type_from_name(&r.get::<_, String>(0)?),
                        r.get::<_, i64>(1)? as usize,
                    ))
                })?
                .collect::<rusqlite::Result<_>>()?;
            let cardinality: i64 = c
                .prepare_cached(
                    "SELECT COUNT(*) FROM position_values WHERE host = ? AND scope = ? AND locator = ?",
                )?
                .query_row(key, |r| r.get(0))?;
            let value_count: Option<i64> = c
                .prepare_cached(
                    "SELECT count FROM position_values WHERE host = ? AND scope = ? AND locator = ? AND value = ?",
                )?
                .query_row(params![pos.host, pos.scope.as_str(), pos.locator, value], |r| {
                    r.get(0)
                })
                .optional()?;
            Ok(Some(PositionEvidence {
                total: total as usize,
                type_counts,
                cardinality: cardinality as usize,
                value_count: value_count.map(|n| n as usize),
            }))
        };
        read().map_err(|e| Error::sqlite(&self.path, e))
    }

    fn param_stats_for(&self, cluster_key: &str, name: &str) -> Result<Option<PositionStats>> {
        let c = self.conn();
        let read = || -> rusqlite::Result<Option<PositionStats>> {
            let Some(total) = c
                .prepare_cached(
                    "SELECT total FROM cluster_params WHERE cluster_key = ? AND name = ?",
                )?
                .query_row(params![cluster_key, name], |r| r.get::<_, i64>(0))
                .optional()?
            else {
                return Ok(None);
            };
            let mut stats = PositionStats::new(self.max_values);
            stats.total = total as usize;
            stats.value_counts = c
                .prepare_cached(
                    "SELECT value, count FROM cluster_param_values WHERE cluster_key = ? AND name = ?",
                )?
                .query_map(params![cluster_key, name], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as usize))
                })?
                .collect::<rusqlite::Result<_>>()?;
            stats.type_counts = c
                .prepare_cached(
                    "SELECT type, count FROM cluster_param_types WHERE cluster_key = ? AND name = ?",
                )?
                .query_map(params![cluster_key, name], |r| {
                    Ok((
                        segment_type_from_name(&r.get::<_, String>(0)?),
                        r.get::<_, i64>(1)? as usize,
                    ))
                })?
                .collect::<rusqlite::Result<_>>()?;
            rebuild_numeric_stats(&mut stats);
            Ok(Some(stats))
        };
        read().map_err(|e| Error::sqlite(&self.path, e))
    }

    fn record_observation(&mut self, canonical: &str) -> Result<()> {
        let c = self.conn.get_mut().unwrap_or_else(PoisonError::into_inner);
        c.prepare_cached("INSERT INTO observed_iris (canonical) VALUES (?)")
            .and_then(|mut s| s.execute(params![canonical]))
            .map_err(|e| Error::sqlite(&self.path, e))?;
        Ok(())
    }
    fn each_observed_iri(&self, f: &mut dyn FnMut(&str)) -> Result<()> {
        let iris: Vec<String> = self.read(|c| {
            let mut stmt = c.prepare("SELECT canonical FROM observed_iris ORDER BY id")?;
            let rows = stmt.query_map([], |r| r.get(0))?;
            rows.collect()
        })?;
        for iri in &iris {
            f(iri);
        }
        Ok(())
    }
    fn observed_iri_count(&self) -> Result<usize> {
        self.read(|c| {
            c.query_row("SELECT COUNT(*) FROM observed_iris", [], |r| {
                r.get::<_, i64>(0)
            })
        })
        .map(|n| n as usize)
    }
    fn clear_materialized_views(&mut self) -> Result<()> {
        self.value_counts.clear();
        let c = self.conn.get_mut().unwrap_or_else(PoisonError::into_inner);
        for q in [
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
        ] {
            c.execute(q, []).map_err(|e| Error::sqlite(&self.path, e))?;
        }
        Ok(())
    }
    fn record_activated_recognizer(&mut self, dump: Value) -> Result<()> {
        let prefix = dump
            .get("prefix")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let ty = dump
            .get("type")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let spec = dump
            .get("specificity")
            .and_then(|v| v.as_f64())
            .unwrap_or(1.0);
        let c = self.conn.get_mut().unwrap_or_else(PoisonError::into_inner);
        c.execute(
            "INSERT INTO activated_recognizers (prefix, type, specificity) VALUES (?, ?, ?) \
             ON CONFLICT(prefix) DO UPDATE SET type = excluded.type, specificity = excluded.specificity",
            params![prefix, ty, spec],
        )
        .map_err(|e| Error::sqlite(&self.path, e))?;
        Ok(())
    }
    fn each_activated_recognizer(&self, f: &mut dyn FnMut(&Value)) -> Result<()> {
        let rows: Vec<(String, String, f64)> = self.read(|c| {
            let mut stmt = c.prepare(
                "SELECT prefix, type, specificity FROM activated_recognizers ORDER BY prefix",
            )?;
            let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
            rows.collect()
        })?;
        for (prefix, ty, specificity) in rows {
            let mut m = Map::new();
            m.insert("prefix".to_string(), Value::String(prefix));
            m.insert("type".to_string(), Value::String(ty));
            m.insert(
                "specificity".to_string(),
                Value::Number(serde_json::Number::from_f64(specificity).unwrap()),
            );
            f(&Value::Object(m));
        }
        Ok(())
    }
    fn activated_recognizer_count(&self) -> Result<usize> {
        self.read(|c| {
            c.query_row("SELECT COUNT(*) FROM activated_recognizers", [], |r| {
                r.get::<_, i64>(0)
            })
        })
        .map(|n| n as usize)
    }

    // A batch inside a batch joins it, as in Ruby. A savepoint per nested
    // batch would let it roll back alone, but costs a statement journal per
    // observation on every batched ingest.
    fn batch_begin(&mut self) -> Result<()> {
        if self.depth > 0 {
            self.depth += 1;
            return Ok(());
        }
        let c = self.conn.get_mut().unwrap_or_else(PoisonError::into_inner);
        c.execute_batch("BEGIN IMMEDIATE")
            .map_err(|e| Error::sqlite(&self.path, e))?;
        // Under the write lock no one else can commit until we do, so a
        // version read now stays true for the whole batch.
        let version = c
            .query_row("PRAGMA data_version", [], |r| r.get::<_, i64>(0))
            .ok();
        if version.is_none() || version != self.counts_version {
            self.value_counts.clear();
        }
        self.counts_version = version;
        self.depth = 1;
        Ok(())
    }
    fn batch_commit(&mut self) -> Result<()> {
        self.depth -= 1;
        if self.depth > 0 {
            return Ok(());
        }
        let c = self.conn.get_mut().unwrap_or_else(PoisonError::into_inner);
        let committed = c.execute_batch("COMMIT");
        if committed.is_err() {
            self.value_counts.clear();
            // Most failed commits end the transaction; one that doesn't (a
            // deferred constraint) would keep the write lock and refuse every
            // later batch. The commit error is the one worth reporting.
            if !c.is_autocommit() {
                let _ = c.execute_batch("ROLLBACK");
            }
        }
        committed.map_err(|e| Error::sqlite(&self.path, e))
    }
    fn batch_rollback(&mut self) -> Result<()> {
        self.depth -= 1;
        if self.depth > 0 {
            return Ok(());
        }
        self.value_counts.clear();
        let c = self.conn.get_mut().unwrap_or_else(PoisonError::into_inner);
        c.execute_batch("ROLLBACK")
            .map_err(|e| Error::sqlite(&self.path, e))
    }

    fn flush(&mut self) -> Result<()> {
        Ok(())
    }
    fn close(&mut self) -> Result<()> {
        let c = self.conn.get_mut().unwrap_or_else(PoisonError::into_inner);
        // Checkpointing only compacts the WAL; committed data is already safe.
        let _ = c.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
        Ok(())
    }
    fn save_to(&mut self, path: &Path) -> Result<()> {
        // Mirror the contents into a fresh MemoryStorage and write JSON.
        let mut mem = MemoryStorage::new(self.max_values);
        mirror_into_memory(self, &mut mem)?;
        crate::storage_json::dump_memory_to_json(&mem, path)
    }
    fn path(&self) -> Option<&Path> {
        Some(&self.path)
    }
}

fn counts_hash(
    c: &Connection,
    table: &str,
    key_col: &str,
) -> rusqlite::Result<HashMap<String, usize>> {
    let mut stmt = c.prepare(&format!("SELECT {key_col}, count FROM {table}"))?;
    let rows = stmt.query_map([], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as usize))
    })?;
    rows.collect()
}

fn load_cluster(c: &Connection, key: &str, max_values: usize) -> rusqlite::Result<Option<Cluster>> {
    let Some((host, scheme, shape, count)) = c
        .prepare_cached("SELECT host, scheme, shape, count FROM clusters WHERE key = ?")?
        .query_row(params![key], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, i64>(3)?,
            ))
        })
        .optional()?
    else {
        return Ok(None);
    };
    let mut cluster = Cluster::new(key.to_string(), host, scheme, shape, max_values);
    cluster.count = count as usize;

    let mut stmt = c.prepare_cached(
        "SELECT canonical FROM cluster_examples WHERE cluster_key = ? ORDER BY position",
    )?;
    for canon in stmt.query_map(params![key], |r| r.get::<_, String>(0))? {
        // As the JSON loader does, an example that no longer parses is skipped.
        if let Ok(iri) = parse(&canon?) {
            cluster.register_example_key(iri.canonical());
            cluster.examples.push(std::sync::Arc::new(iri));
        }
    }

    let mut stmt = c.prepare_cached(
        "SELECT position, value, count FROM cluster_segments WHERE cluster_key = ? ORDER BY position",
    )?;
    let rows = stmt.query_map(params![key], |r| {
        Ok((
            r.get::<_, i64>(0)? as usize,
            r.get::<_, String>(1)?,
            r.get::<_, i64>(2)? as usize,
        ))
    })?;
    for row in rows {
        let (pos, value, count) = row?;
        while cluster.segment_counts.len() <= pos {
            cluster.segment_counts.push(HashMap::new());
        }
        cluster.segment_counts[pos].insert(value, count);
    }

    let mut stmt =
        c.prepare_cached("SELECT name, total FROM cluster_params WHERE cluster_key = ?")?;
    let rows = stmt.query_map(params![key], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as usize))
    })?;
    for row in rows {
        let (name, total) = row?;
        let mut stats = PositionStats::new(max_values);
        stats.total = total;
        cluster.param_stats.insert(name, stats);
    }
    let mut stmt = c.prepare_cached(
        "SELECT name, value, count FROM cluster_param_values WHERE cluster_key = ?",
    )?;
    let rows = stmt.query_map(params![key], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, i64>(2)? as usize,
        ))
    })?;
    for row in rows {
        let (name, value, count) = row?;
        if let Some(stats) = cluster.param_stats.get_mut(&name) {
            stats.value_counts.insert(value, count);
        }
    }
    let mut stmt = c.prepare_cached(
        "SELECT name, type, count FROM cluster_param_types WHERE cluster_key = ?",
    )?;
    let rows = stmt.query_map(params![key], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, i64>(2)? as usize,
        ))
    })?;
    for row in rows {
        let (name, ty, count) = row?;
        if let Some(stats) = cluster.param_stats.get_mut(&name) {
            stats.type_counts.insert(segment_type_from_name(&ty), count);
        }
    }
    for stats in cluster.param_stats.values_mut() {
        rebuild_numeric_stats(stats);
    }
    Ok(Some(cluster))
}

fn mirror_into_memory(src: &SqliteStorage, dst: &mut MemoryStorage) -> Result<()> {
    for (k, v) in src.host_counts()? {
        for _ in 0..v {
            dst.increment_host(&k)?;
        }
    }
    for (k, v) in src.path_length_counts()? {
        for _ in 0..v {
            dst.increment_path_length(k)?;
        }
    }
    for (k, v) in src.raw_shape_counts()? {
        for _ in 0..v {
            dst.increment_raw_shape(&k)?;
        }
    }
    for (k, v) in src.fingerprint_counts()? {
        for _ in 0..v {
            dst.increment_fingerprint(&k)?;
        }
    }
    src.each_position_stats(&mut |pos, stats| {
        dst.insert_position_stats(pos.clone(), stats.clone());
    })?;
    for c in src.clusters()? {
        dst.insert_cluster(c.key.clone(), c);
    }
    let mut observed = Vec::new();
    src.each_observed_iri(&mut |c| observed.push(c.to_string()))?;
    for c in &observed {
        dst.record_observation(c)?;
    }
    let mut recognizers = Vec::new();
    src.each_activated_recognizer(&mut |v| recognizers.push(v.clone()))?;
    for v in recognizers {
        dst.record_activated_recognizer(v)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Corpus;
    use std::panic::{catch_unwind, AssertUnwindSafe};
    use std::time::Duration;

    fn temp_db(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("iriq-sqlite-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("c.db")
    }

    #[test]
    fn a_panicking_reader_callback_leaves_the_storage_usable() {
        let mut s = SqliteStorage::open(&temp_db("poison"), 0).unwrap();
        s.record_observation("https://x.com/1").unwrap();
        let panicked = catch_unwind(AssertUnwindSafe(|| {
            let _ = s.each_observed_iri(&mut |_| panic!("bug in a callback"));
        }));
        assert!(panicked.is_err());
        s.record_observation("https://x.com/2").unwrap();
        assert_eq!(s.observed_iri_count().unwrap(), 2);
    }

    #[test]
    fn reader_callbacks_may_reenter_the_storage() {
        let path = temp_db("reenter");
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut s = SqliteStorage::open(&path, 0).unwrap();
            s.record_observation("https://x.com/1").unwrap();
            s.record_activated_recognizer(serde_json::json!({"prefix": "tok_", "type": "tok"}))
                .unwrap();
            let mut seen = 0;
            s.each_observed_iri(&mut |_| seen += s.observed_iri_count().unwrap())
                .unwrap();
            s.each_activated_recognizer(&mut |_| seen += s.activated_recognizer_count().unwrap())
                .unwrap();
            tx.send(seen).unwrap();
        });
        let seen = rx
            .recv_timeout(Duration::from_secs(5))
            .expect("a re-entrant read deadlocked");
        assert_eq!(seen, 2);
    }

    #[test]
    fn a_write_failing_late_in_an_observation_is_reported() {
        let path = temp_db("late");
        let mut corpus = Corpus::open(&path).unwrap();
        // The source-log insert is the last write an observation makes.
        rusqlite::Connection::open(&path)
            .unwrap()
            .execute_batch(
                "CREATE TRIGGER no_obs BEFORE INSERT ON observed_iris \
                 BEGIN SELECT RAISE(ABORT, 'simulated write failure'); END;",
            )
            .unwrap();

        let err = corpus.observe("https://x.com/users/1").unwrap_err();
        let cause = std::error::Error::source(&err).unwrap().to_string();
        assert!(cause.contains("simulated write failure"), "{cause}");
        assert_eq!(corpus.observed_iri_count().unwrap(), 0);
    }

    #[test]
    fn a_failed_commit_ends_its_transaction() {
        let path = temp_db("failed-commit");
        let mut corpus = Corpus::open(&path).unwrap();
        // A deferred foreign-key violation fails COMMIT itself and, unlike most
        // commit failures, leaves the transaction open.
        Connection::open(&path)
            .unwrap()
            .execute_batch(
                "CREATE TABLE fkp (id INTEGER PRIMARY KEY);
                 CREATE TABLE fkc (pid INTEGER REFERENCES fkp(id) DEFERRABLE INITIALLY DEFERRED);
                 CREATE TRIGGER boom AFTER INSERT ON observed_iris WHEN NEW.canonical LIKE '%boom%'
                 BEGIN INSERT INTO fkc VALUES (999); END;",
            )
            .unwrap();

        let err = corpus.observe("https://x.com/boom/1").unwrap_err();
        let cause = std::error::Error::source(&err).unwrap().to_string();
        assert!(cause.contains("FOREIGN KEY"), "{cause}");

        corpus
            .observe("https://x.com/fine/2")
            .expect("an observation after the failed commit");
        Connection::open(&path)
            .unwrap()
            .execute_batch("BEGIN IMMEDIATE; ROLLBACK;")
            .expect("the failed commit kept the write lock");
        assert_eq!(corpus.observed_iri_count().unwrap(), 1);
    }

    #[test]
    fn a_corpus_from_a_newer_schema_is_refused_untouched() {
        let path = temp_db("newer-schema");
        Corpus::open(&path).unwrap().close().unwrap();
        let stored_version = |conn: &Connection| -> String {
            conn.query_row(
                "SELECT value FROM meta WHERE key = 'schema_version'",
                [],
                |r| r.get(0),
            )
            .unwrap()
        };
        let conn = Connection::open(&path).unwrap();
        conn.execute(
            "UPDATE meta SET value = ? WHERE key = 'schema_version'",
            params![(SCHEMA_VERSION + 1).to_string()],
        )
        .unwrap();

        let err = Corpus::open(&path).expect_err("opened a corpus from a newer schema");
        assert!(matches!(err, Error::Unsupported { .. }), "{err:?}");
        assert!(err.to_string().contains("newer"), "{err}");
        assert_eq!(stored_version(&conn), (SCHEMA_VERSION + 1).to_string());
    }

    #[test]
    fn reloaded_position_stats_keep_infinite_values_out_of_the_range() {
        let mut s = SqliteStorage::open(&temp_db("nonfinite"), 0).unwrap();
        let pos = Position::path("inf.com", "/p");
        s.observe_position(&pos, "1", SegmentType::Integer).unwrap();
        s.observe_position(&pos, &"1".repeat(400), SegmentType::Integer)
            .unwrap();

        let stats = s.position_stats_for(&pos).unwrap().unwrap();
        assert_eq!(stats.total, 2);
        assert_eq!(
            (stats.numeric_count, stats.numeric_min, stats.numeric_max),
            (1, 1.0, 1.0)
        );
    }

    #[test]
    fn a_cluster_keeps_its_first_seen_order_as_it_grows() {
        let mut s = SqliteStorage::open(&temp_db("ord"), 0).unwrap();
        for url in [
            "https://a.com/1",
            "https://b.com/1",
            "https://a.com/2",
            "https://c.com/1",
        ] {
            let iri = parse(url).unwrap();
            s.add_to_cluster(&iri.host, &iri.host, "https", "/{id}", &iri)
                .unwrap();
        }
        let listed: Vec<(String, usize)> = s
            .clusters()
            .unwrap()
            .into_iter()
            .map(|c| (c.key, c.count))
            .collect();
        assert_eq!(
            listed,
            [
                ("a.com".into(), 2),
                ("b.com".into(), 1),
                ("c.com".into(), 1)
            ]
        );
        let ords: Vec<i64> = {
            let c = s.conn();
            let mut stmt = c.prepare("SELECT ord FROM clusters ORDER BY ord").unwrap();
            let rows = stmt.query_map([], |r| r.get(0)).unwrap();
            rows.map(|r| r.unwrap()).collect()
        };
        assert_eq!(ords, [1, 2, 3]);
    }
}
