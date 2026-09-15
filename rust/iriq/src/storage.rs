use crate::classifier::SegmentType;
use crate::cluster::Cluster;
use crate::errors::{ParseError, Result};
use crate::identifier::Identifier;
use crate::position::Position;
use crate::position_stats::PositionStats;
use std::collections::HashMap;
use std::path::Path;

/// Persistence layer behind a Corpus. Phase-2 ships Memory, JSON, and
/// SQLite (optional via feature). Backends update materialized views and
/// own the source-IRI log used by Reinfer. Every write reports failure.
pub trait Storage: Send + Sync {
    fn max_values(&self) -> usize;

    fn increment_host(&mut self, host: &str) -> Result<()>;
    fn increment_path_length(&mut self, length: usize) -> Result<()>;
    fn increment_raw_shape(&mut self, shape: &str) -> Result<()>;
    fn increment_fingerprint(&mut self, shape: &str) -> Result<()>;
    fn observe_position(&mut self, pos: &Position, value: &str, t: SegmentType) -> Result<()>;
    fn add_to_cluster(
        &mut self,
        key: &str,
        host: &str,
        scheme: &str,
        shape: &str,
        iri: &Identifier,
    ) -> Result<()>;

    fn host_counts(&self) -> HashMap<String, usize>;
    fn path_length_counts(&self) -> HashMap<usize, usize>;
    fn raw_shape_counts(&self) -> HashMap<String, usize>;
    fn fingerprint_counts(&self) -> HashMap<String, usize>;
    /// Visit each (host, count) without materializing a HashMap. Default
    /// falls back to a full materialization for backends that can't stream.
    fn for_each_host(&self, f: &mut dyn FnMut(&str, usize)) {
        for (k, v) in self.host_counts() {
            f(&k, v);
        }
    }
    fn for_each_raw_shape(&self, f: &mut dyn FnMut(&str, usize)) {
        for (k, v) in self.raw_shape_counts() {
            f(&k, v);
        }
    }
    fn for_each_fingerprint(&self, f: &mut dyn FnMut(&str, usize)) {
        for (k, v) in self.fingerprint_counts() {
            f(&k, v);
        }
    }
    fn position_stats_for(&self, pos: &Position) -> Option<PositionStats>;
    fn each_position_stats(&self, f: &mut dyn FnMut(&Position, &PositionStats));
    fn clusters(&self) -> Vec<Cluster>;
    fn cluster_for(&self, key: &str) -> Option<Cluster>;
    fn cluster_size(&self) -> usize;

    fn record_observation(&mut self, canonical: &str) -> Result<()>;
    fn each_observed_iri(&self, f: &mut dyn FnMut(&str));
    fn observed_iri_count(&self) -> usize;
    fn clear_materialized_views(&mut self) -> Result<()>;

    fn record_activated_recognizer(&mut self, dump: serde_json::Value) -> Result<()>;
    fn each_activated_recognizer(&self, f: &mut dyn FnMut(&serde_json::Value));
    fn activated_recognizer_count(&self) -> usize;

    /// One backend transaction around many writes. SQLite turns
    /// O(observations) commits into one; Memory + JSON are no-ops.
    fn batch_begin(&mut self) -> Result<()> {
        Ok(())
    }
    fn batch_commit(&mut self) -> Result<()> {
        Ok(())
    }
    fn batch_rollback(&mut self) -> Result<()> {
        Ok(())
    }

    fn flush(&mut self) -> Result<()> {
        Ok(())
    }
    fn close(&mut self) -> Result<()> {
        Ok(())
    }
    fn save_to(&mut self, path: &Path) -> Result<()>;
    fn path(&self) -> Option<&Path> {
        None
    }
}

/// Pick the backend by file extension. Empty path → in-memory.
pub fn open_storage(path: &Path, max_values: usize) -> Result<Box<dyn Storage>> {
    if path.as_os_str().is_empty() {
        return Ok(Box::new(crate::storage_memory::MemoryStorage::new(
            max_values,
        )));
    }
    if is_sqlite_path(path) {
        #[cfg(feature = "sqlite")]
        return Ok(Box::new(crate::storage_sqlite::SqliteStorage::open(
            path, max_values,
        )?));
        #[cfg(not(feature = "sqlite"))]
        return Err(crate::errors::Error::unsupported(
            path,
            "built without the `sqlite` feature; use a .json corpus instead",
        ));
    }
    Ok(Box::new(crate::storage_json::JsonStorage::open(
        path, max_values,
    )?))
}

/// `.db`, `.sqlite`, and `.sqlite3` (any case) name a SQLite corpus.
pub(crate) fn is_sqlite_path(path: &Path) -> bool {
    path.extension().and_then(|e| e.to_str()).is_some_and(|e| {
        let e = e.to_ascii_lowercase();
        e == "db" || e == "sqlite" || e == "sqlite3"
    })
}

/// Coerce an arbitrary input into an Identifier. Helper used by Corpus.
pub fn coerce_identifier(s: &str) -> std::result::Result<Identifier, ParseError> {
    crate::parser::parse(s)
}
