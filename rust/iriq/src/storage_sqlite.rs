// SQLite-backed corpus storage. Mirrors Ruby's storage/sqlite.rb schema
// byte-for-byte so a corpus created by either runtime opens cleanly in
// the other.

use crate::classifier::{segment_type_from_str, SegmentType, DEFAULT_CLASSIFIER};
use crate::cluster::{Cluster, MAX_CLUSTER_EXAMPLES};
use crate::identifier::Identifier;
use crate::parser::parse;
use crate::position::{Position, PositionScope};
use crate::position_stats::{PositionStats, DEFAULT_MAX_VALUES_PER_POSITION};
use crate::storage::Storage;
use crate::storage_memory::MemoryStorage;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::sync::Mutex;

const SCHEMA: &str = include_str!("./sqlite_schema.sql");
const SCHEMA_VERSION: i64 = 4;

pub struct SqliteStorage {
    conn: Mutex<Connection>,
    max_values: usize,
    path: String,
}

impl SqliteStorage {
    pub fn open(path: &str, max_values: usize) -> std::io::Result<Self> {
        let conn = Connection::open(path).map_err(rs_err)?;
        // PRAGMAs first (busy_timeout before journal_mode).
        conn.execute_batch("PRAGMA busy_timeout = 30000;")
            .map_err(rs_err)?;
        conn.execute_batch("PRAGMA journal_mode = WAL;")
            .map_err(rs_err)?;
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
            conn.execute(
                "INSERT INTO meta (key, value) VALUES ('schema_version', ?)",
                params![SCHEMA_VERSION.to_string()],
            )
            .map_err(rs_err)?;
            conn.execute(
                "INSERT INTO meta (key, value) VALUES ('max_values_per_position', ?)",
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
            path: path.to_string(),
        })
    }
}

fn rs_err<E: std::fmt::Display>(e: E) -> std::io::Error {
    std::io::Error::other(e.to_string())
}

impl Storage for SqliteStorage {
    fn max_values(&self) -> usize {
        self.max_values
    }

    fn increment_host(&mut self, host: &str) {
        let c = self.conn.lock().unwrap();
        let mut stmt = c
            .prepare_cached(
                "INSERT INTO host_counts (host, count) VALUES (?, 1) ON CONFLICT(host) DO UPDATE SET count = count + 1",
            )
            .unwrap();
        let _ = stmt.execute(params![host]);
    }
    fn increment_path_length(&mut self, length: usize) {
        let c = self.conn.lock().unwrap();
        let mut stmt = c
            .prepare_cached(
                "INSERT INTO path_length_counts (length, count) VALUES (?, 1) ON CONFLICT(length) DO UPDATE SET count = count + 1",
            )
            .unwrap();
        let _ = stmt.execute(params![length as i64]);
    }
    fn increment_raw_shape(&mut self, shape: &str) {
        let c = self.conn.lock().unwrap();
        let mut stmt = c
            .prepare_cached(
                "INSERT INTO raw_shape_counts (shape, count) VALUES (?, 1) ON CONFLICT(shape) DO UPDATE SET count = count + 1",
            )
            .unwrap();
        let _ = stmt.execute(params![shape]);
    }
    fn increment_fingerprint(&mut self, shape: &str) {
        let c = self.conn.lock().unwrap();
        let mut stmt = c
            .prepare_cached(
                "INSERT INTO fingerprint_counts (shape, count) VALUES (?, 1) ON CONFLICT(shape) DO UPDATE SET count = count + 1",
            )
            .unwrap();
        let _ = stmt.execute(params![shape]);
    }

    fn observe_position(&mut self, pos: &Position, value: &str, t: SegmentType) {
        let c = self.conn.lock().unwrap();
        let scope = pos.scope.as_str();
        {
            let mut stmt = c
                .prepare_cached(
                    "INSERT INTO position_stats (host, scope, locator, total) VALUES (?, ?, ?, 1) \
                     ON CONFLICT(host, scope, locator) DO UPDATE SET total = total + 1",
                )
                .unwrap();
            let _ = stmt.execute(params![pos.host, scope, pos.locator]);
        }
        {
            let mut stmt = c
                .prepare_cached(
                    "INSERT INTO position_types (host, scope, locator, type, count) VALUES (?, ?, ?, ?, 1) \
                     ON CONFLICT(host, scope, locator, type) DO UPDATE SET count = count + 1",
                )
                .unwrap();
            let _ = stmt.execute(params![pos.host, scope, pos.locator, t.as_str()]);
        }
        let updated = {
            let mut stmt = c
                .prepare_cached(
                    "UPDATE position_values SET count = count + 1 WHERE host = ? AND scope = ? AND locator = ? AND value = ?",
                )
                .unwrap();
            stmt.execute(params![pos.host, scope, pos.locator, value])
                .unwrap_or(0)
        };
        if updated == 0 {
            let card: i64 = {
                let mut stmt = c
                    .prepare_cached(
                        "SELECT COUNT(*) FROM position_values WHERE host = ? AND scope = ? AND locator = ?",
                    )
                    .unwrap();
                stmt.query_row(params![pos.host, scope, pos.locator], |r| r.get(0))
                    .unwrap_or(0)
            };
            if (card as usize) < self.max_values {
                let mut stmt = c
                    .prepare_cached(
                        "INSERT INTO position_values (host, scope, locator, value, count) VALUES (?, ?, ?, ?, 1)",
                    )
                    .unwrap();
                let _ = stmt.execute(params![pos.host, scope, pos.locator, value]);
            }
        }
    }

    fn add_to_cluster(
        &mut self,
        key: &str,
        host: &str,
        scheme: &str,
        shape: &str,
        iri: &Identifier,
    ) {
        let c = self.conn.lock().unwrap();
        {
            let mut stmt = c
                .prepare_cached(
                    "INSERT INTO clusters (key, host, scheme, shape, count, ord) \
                     VALUES (?, ?, ?, ?, 1, (SELECT COALESCE(MAX(ord), 0) + 1 FROM clusters)) \
                     ON CONFLICT(key) DO UPDATE SET count = count + 1",
                )
                .unwrap();
            let _ = stmt.execute(params![key, host, scheme, shape]);
        }

        let examples_count: i64 = {
            let mut stmt = c
                .prepare_cached("SELECT COUNT(*) FROM cluster_examples WHERE cluster_key = ?")
                .unwrap();
            stmt.query_row(params![key], |r| r.get(0)).unwrap_or(0)
        };
        if (examples_count as usize) < MAX_CLUSTER_EXAMPLES {
            let canon = iri.canonical();
            let exists: i64 = {
                let mut stmt = c
                    .prepare_cached(
                        "SELECT COUNT(*) FROM cluster_examples WHERE cluster_key = ? AND canonical = ?",
                    )
                    .unwrap();
                stmt.query_row(params![key, canon], |r| r.get(0))
                    .unwrap_or(0)
            };
            if exists == 0 {
                let mut stmt = c
                    .prepare_cached(
                        "INSERT INTO cluster_examples (cluster_key, position, canonical) VALUES (?, ?, ?)",
                    )
                    .unwrap();
                let _ = stmt.execute(params![key, examples_count, canon]);
            }
        }

        {
            let mut stmt = c
                .prepare_cached(
                    "INSERT INTO cluster_segments (cluster_key, position, value, count) VALUES (?, ?, ?, 1) \
                     ON CONFLICT(cluster_key, position, value) DO UPDATE SET count = count + 1",
                )
                .unwrap();
            for (i, seg) in iri.path_segments.iter().enumerate() {
                let _ = stmt.execute(params![key, i as i64, seg]);
            }
        }

        let classifier = &DEFAULT_CLASSIFIER;
        for (name, v) in iri.query_params.iter() {
            let t = classifier.classify(v);
            {
                let mut stmt = c
                    .prepare_cached(
                        "INSERT INTO cluster_params (cluster_key, name, total) VALUES (?, ?, 1) \
                         ON CONFLICT(cluster_key, name) DO UPDATE SET total = total + 1",
                    )
                    .unwrap();
                let _ = stmt.execute(params![key, name]);
            }
            {
                let mut stmt = c
                    .prepare_cached(
                        "INSERT INTO cluster_param_types (cluster_key, name, type, count) VALUES (?, ?, ?, 1) \
                         ON CONFLICT(cluster_key, name, type) DO UPDATE SET count = count + 1",
                    )
                    .unwrap();
                let _ = stmt.execute(params![key, name, t.as_str()]);
            }
            let updated = {
                let mut stmt = c
                    .prepare_cached(
                        "UPDATE cluster_param_values SET count = count + 1 WHERE cluster_key = ? AND name = ? AND value = ?",
                    )
                    .unwrap();
                stmt.execute(params![key, name, v]).unwrap_or(0)
            };
            if updated == 0 {
                let card: i64 = {
                    let mut stmt = c
                        .prepare_cached(
                            "SELECT COUNT(*) FROM cluster_param_values WHERE cluster_key = ? AND name = ?",
                        )
                        .unwrap();
                    stmt.query_row(params![key, name], |r| r.get(0))
                        .unwrap_or(0)
                };
                if (card as usize) < self.max_values {
                    let mut stmt = c
                        .prepare_cached(
                            "INSERT INTO cluster_param_values (cluster_key, name, value, count) VALUES (?, ?, ?, 1)",
                        )
                        .unwrap();
                    let _ = stmt.execute(params![key, name, v]);
                }
            }
        }
    }

    fn host_counts(&self) -> HashMap<String, usize> {
        counts_hash(&self.conn.lock().unwrap(), "host_counts", "host")
    }
    fn path_length_counts(&self) -> HashMap<usize, usize> {
        let c = self.conn.lock().unwrap();
        let mut out = HashMap::new();
        let mut stmt = c
            .prepare("SELECT length, count FROM path_length_counts")
            .unwrap();
        let rows = stmt
            .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))
            .unwrap();
        for row in rows.flatten() {
            out.insert(row.0 as usize, row.1 as usize);
        }
        out
    }
    fn raw_shape_counts(&self) -> HashMap<String, usize> {
        counts_hash(&self.conn.lock().unwrap(), "raw_shape_counts", "shape")
    }
    fn fingerprint_counts(&self) -> HashMap<String, usize> {
        counts_hash(&self.conn.lock().unwrap(), "fingerprint_counts", "shape")
    }

    fn position_stats_for(&self, pos: &Position) -> Option<PositionStats> {
        let c = self.conn.lock().unwrap();
        let total: i64 = c
            .query_row(
                "SELECT total FROM position_stats WHERE host = ? AND scope = ? AND locator = ?",
                params![pos.host, pos.scope.as_str(), pos.locator],
                |r| r.get(0),
            )
            .optional()
            .ok()
            .flatten()?;
        let mut ps = PositionStats::new(self.max_values);
        ps.total = total as usize;

        {
            let mut stmt = c
                .prepare(
                    "SELECT value, count FROM position_values WHERE host = ? AND scope = ? AND locator = ?",
                )
                .unwrap();
            let rows = stmt
                .query_map(params![pos.host, pos.scope.as_str(), pos.locator], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
                })
                .unwrap();
            for row in rows.flatten() {
                ps.value_counts.insert(row.0, row.1 as usize);
            }
        }
        {
            let mut stmt = c
                .prepare(
                    "SELECT type, count FROM position_types WHERE host = ? AND scope = ? AND locator = ?",
                )
                .unwrap();
            let rows = stmt
                .query_map(params![pos.host, pos.scope.as_str(), pos.locator], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
                })
                .unwrap();
            for row in rows.flatten() {
                if let Some(t) = segment_type_from_str(&row.0) {
                    ps.type_counts.insert(t, row.1 as usize);
                }
            }
        }
        // Recompute numeric stats from value_counts × types — same approach
        // as JSON load, same caveat (cap-trimmed values are lost).
        if ps
            .type_counts
            .get(&SegmentType::Integer)
            .copied()
            .unwrap_or(0)
            + ps.type_counts
                .get(&SegmentType::Float)
                .copied()
                .unwrap_or(0)
            > 0
        {
            for (v, n) in &ps.value_counts {
                if let Ok(num) = v.parse::<f64>() {
                    for _ in 0..*n {
                        if ps.numeric_count == 0 || num < ps.numeric_min {
                            ps.numeric_min = num;
                        }
                        if ps.numeric_count == 0 || num > ps.numeric_max {
                            ps.numeric_max = num;
                        }
                        ps.numeric_count += 1;
                        ps.numeric_sum += num;
                    }
                }
            }
        }
        Some(ps)
    }

    fn each_position_stats(&self, f: &mut dyn FnMut(&Position, &PositionStats)) {
        let keys = {
            let c = self.conn.lock().unwrap();
            let mut stmt = c
                .prepare("SELECT host, scope, locator FROM position_stats ORDER BY ROWID")
                .unwrap();
            let rows = stmt
                .query_map([], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                    ))
                })
                .unwrap();
            rows.filter_map(|r| {
                r.ok().map(|(h, sc, l)| Position {
                    host: h,
                    scope: if sc == "query" {
                        PositionScope::Query
                    } else {
                        PositionScope::Path
                    },
                    locator: l,
                })
            })
            .collect::<Vec<_>>()
        };
        for k in keys {
            if let Some(stats) = self.position_stats_for(&k) {
                f(&k, &stats);
            }
        }
    }

    fn clusters(&self) -> Vec<Cluster> {
        let keys: Vec<String> = {
            let c = self.conn.lock().unwrap();
            let mut stmt = c.prepare("SELECT key FROM clusters ORDER BY ord").unwrap();
            let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
            rows.flatten().collect()
        };
        keys.iter().filter_map(|k| self.cluster_for(k)).collect()
    }
    fn cluster_for(&self, key: &str) -> Option<Cluster> {
        let c = self.conn.lock().unwrap();
        let row: (String, String, String, i64) = c
            .query_row(
                "SELECT host, scheme, shape, count FROM clusters WHERE key = ?",
                params![key],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .optional()
            .ok()
            .flatten()?;
        let mut cluster = Cluster::new(key.to_string(), row.0, row.1, row.2, self.max_values);
        cluster.count = row.3 as usize;

        {
            let mut stmt = c
                .prepare(
                    "SELECT canonical FROM cluster_examples WHERE cluster_key = ? ORDER BY position",
                )
                .unwrap();
            let rows = stmt
                .query_map(params![key], |r| r.get::<_, String>(0))
                .unwrap();
            for canon in rows.flatten() {
                if let Ok(iri) = parse(&canon) {
                    cluster.register_example_key(iri.canonical());
                    cluster.examples.push(std::sync::Arc::new(iri));
                }
            }
        }

        {
            let mut stmt = c
                .prepare(
                    "SELECT position, value, count FROM cluster_segments WHERE cluster_key = ? ORDER BY position",
                )
                .unwrap();
            let rows = stmt
                .query_map(params![key], |r| {
                    Ok((
                        r.get::<_, i64>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, i64>(2)?,
                    ))
                })
                .unwrap();
            for (pos, value, count) in rows.flatten() {
                let pos = pos as usize;
                while cluster.segment_counts.len() <= pos {
                    cluster.segment_counts.push(HashMap::new());
                }
                cluster.segment_counts[pos].insert(value, count as usize);
            }
        }

        {
            let mut stmt = c
                .prepare("SELECT name, total FROM cluster_params WHERE cluster_key = ?")
                .unwrap();
            let rows = stmt
                .query_map(params![key], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
                })
                .unwrap();
            for (name, total) in rows.flatten() {
                let mut stats = PositionStats::new(self.max_values);
                stats.total = total as usize;
                cluster.param_stats.insert(name, stats);
            }
        }
        {
            let mut stmt = c
                .prepare(
                    "SELECT name, value, count FROM cluster_param_values WHERE cluster_key = ?",
                )
                .unwrap();
            let rows = stmt
                .query_map(params![key], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, i64>(2)?,
                    ))
                })
                .unwrap();
            for (name, value, count) in rows.flatten() {
                if let Some(stats) = cluster.param_stats.get_mut(&name) {
                    stats.value_counts.insert(value, count as usize);
                }
            }
        }
        {
            let mut stmt = c
                .prepare("SELECT name, type, count FROM cluster_param_types WHERE cluster_key = ?")
                .unwrap();
            let rows = stmt
                .query_map(params![key], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, i64>(2)?,
                    ))
                })
                .unwrap();
            for (name, t_str, count) in rows.flatten() {
                if let Some(stats) = cluster.param_stats.get_mut(&name) {
                    if let Some(ty) = segment_type_from_str(&t_str) {
                        stats.type_counts.insert(ty, count as usize);
                    }
                }
            }
        }
        // Recompute numeric for each param.
        for stats in cluster.param_stats.values_mut() {
            if stats
                .type_counts
                .get(&SegmentType::Integer)
                .copied()
                .unwrap_or(0)
                + stats
                    .type_counts
                    .get(&SegmentType::Float)
                    .copied()
                    .unwrap_or(0)
                > 0
            {
                for (v, n) in &stats.value_counts.clone() {
                    if let Ok(num) = v.parse::<f64>() {
                        for _ in 0..*n {
                            if stats.numeric_count == 0 || num < stats.numeric_min {
                                stats.numeric_min = num;
                            }
                            if stats.numeric_count == 0 || num > stats.numeric_max {
                                stats.numeric_max = num;
                            }
                            stats.numeric_count += 1;
                            stats.numeric_sum += num;
                        }
                    }
                }
            }
        }
        Some(cluster)
    }
    fn cluster_size(&self) -> usize {
        let c = self.conn.lock().unwrap();
        let n: i64 = c
            .query_row("SELECT COUNT(*) FROM clusters", [], |r| r.get(0))
            .unwrap_or(0);
        n as usize
    }

    fn record_observation(&mut self, canonical: &str) {
        let c = self.conn.lock().unwrap();
        let _ = c.execute(
            "INSERT INTO observed_iris (canonical) VALUES (?)",
            params![canonical],
        );
    }
    fn each_observed_iri(&self, f: &mut dyn FnMut(&str)) {
        let c = self.conn.lock().unwrap();
        let mut stmt = c
            .prepare("SELECT canonical FROM observed_iris ORDER BY id")
            .unwrap();
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
        for r in rows.flatten() {
            f(&r);
        }
    }
    fn observed_iri_count(&self) -> usize {
        let c = self.conn.lock().unwrap();
        let n: i64 = c
            .query_row("SELECT COUNT(*) FROM observed_iris", [], |r| r.get(0))
            .unwrap_or(0);
        n as usize
    }
    fn clear_materialized_views(&mut self) {
        let c = self.conn.lock().unwrap();
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
            let _ = c.execute(q, []);
        }
    }
    fn record_activated_recognizer(&mut self, dump: Value) {
        let c = self.conn.lock().unwrap();
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
        let _ = c.execute(
            "INSERT INTO activated_recognizers (prefix, type, specificity) VALUES (?, ?, ?) \
             ON CONFLICT(prefix) DO UPDATE SET type = excluded.type, specificity = excluded.specificity",
            params![prefix, ty, spec],
        );
    }
    fn each_activated_recognizer(&self, f: &mut dyn FnMut(&Value)) {
        let c = self.conn.lock().unwrap();
        let mut stmt = c
            .prepare("SELECT prefix, type, specificity FROM activated_recognizers ORDER BY prefix")
            .unwrap();
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, f64>(2)?,
                ))
            })
            .unwrap();
        for r in rows.flatten() {
            let mut m = Map::new();
            m.insert("prefix".to_string(), Value::String(r.0));
            m.insert("type".to_string(), Value::String(r.1));
            m.insert(
                "specificity".to_string(),
                Value::Number(serde_json::Number::from_f64(r.2).unwrap()),
            );
            let v = Value::Object(m);
            f(&v);
        }
    }
    fn activated_recognizer_count(&self) -> usize {
        let c = self.conn.lock().unwrap();
        let n: i64 = c
            .query_row("SELECT COUNT(*) FROM activated_recognizers", [], |r| {
                r.get(0)
            })
            .unwrap_or(0);
        n as usize
    }

    fn batch_begin(&mut self) -> std::io::Result<()> {
        let c = self.conn.lock().unwrap();
        c.execute_batch("BEGIN IMMEDIATE").map_err(rs_err)?;
        Ok(())
    }
    fn batch_commit(&mut self) -> std::io::Result<()> {
        let c = self.conn.lock().unwrap();
        c.execute_batch("COMMIT").map_err(rs_err)?;
        Ok(())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
    fn close(&mut self) -> std::io::Result<()> {
        let c = self.conn.lock().unwrap();
        let _ = c.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
        Ok(())
    }
    fn save_to(&mut self, path: &str) -> std::io::Result<()> {
        // Mirror the contents into a fresh MemoryStorage and write JSON.
        let mut mem = MemoryStorage::new(self.max_values);
        mirror_into_memory(self, &mut mem);
        crate::storage_json::dump_memory_to_json(&mem, path)
    }
    fn path(&self) -> Option<String> {
        Some(self.path.clone())
    }
}

fn counts_hash(c: &Connection, table: &str, key_col: &str) -> HashMap<String, usize> {
    let q = format!("SELECT {}, count FROM {}", key_col, table);
    let mut stmt = c.prepare(&q).unwrap();
    let rows = stmt
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))
        .unwrap();
    let mut out = HashMap::new();
    for r in rows.flatten() {
        out.insert(r.0, r.1 as usize);
    }
    out
}

fn mirror_into_memory(src: &SqliteStorage, dst: &mut MemoryStorage) {
    for (k, v) in src.host_counts() {
        for _ in 0..v {
            dst.increment_host(&k);
        }
    }
    for (k, v) in src.path_length_counts() {
        for _ in 0..v {
            dst.increment_path_length(k);
        }
    }
    for (k, v) in src.raw_shape_counts() {
        for _ in 0..v {
            dst.increment_raw_shape(&k);
        }
    }
    for (k, v) in src.fingerprint_counts() {
        for _ in 0..v {
            dst.increment_fingerprint(&k);
        }
    }
    src.each_position_stats(&mut |pos, stats| {
        dst.insert_position_stats(pos.clone(), stats.clone());
    });
    for c in src.clusters() {
        dst.insert_cluster(c.key.clone(), c);
    }
    src.each_observed_iri(&mut |c| dst.record_observation(c));
    src.each_activated_recognizer(&mut |v| dst.record_activated_recognizer(v.clone()));
}
