use crate::classifier::SegmentType;
use crate::cluster::Cluster;
use crate::errors::ParseError;
use crate::identifier::Identifier;
use crate::position::Position;
use crate::position_stats::PositionStats;
use std::collections::HashMap;

/// Persistence layer behind a Corpus. Phase-2 ships Memory, JSON, and
/// SQLite (optional via feature). Backends update materialized views and
/// own the source-IRI log used by Reinfer.
pub trait Storage: Send + Sync {
    fn max_values(&self) -> usize;

    fn increment_host(&mut self, host: &str);
    fn increment_path_length(&mut self, length: usize);
    fn increment_raw_shape(&mut self, shape: &str);
    fn increment_fingerprint(&mut self, shape: &str);
    fn observe_position(&mut self, pos: &Position, value: &str, t: SegmentType);
    fn add_to_cluster(
        &mut self,
        key: &str,
        host: &str,
        scheme: &str,
        shape: &str,
        iri: &Identifier,
    );

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

    fn record_observation(&mut self, canonical: &str);
    fn each_observed_iri(&self, f: &mut dyn FnMut(&str));
    fn observed_iri_count(&self) -> usize;
    fn clear_materialized_views(&mut self);

    fn record_activated_recognizer(&mut self, dump: serde_json::Value);
    fn each_activated_recognizer(&self, f: &mut dyn FnMut(&serde_json::Value));
    fn activated_recognizer_count(&self) -> usize;

    /// Wraps a closure in a single backend transaction. SQLite turns
    /// O(observations) fsyncs into one; Memory + JSON are no-ops.
    fn batch_begin(&mut self) -> std::io::Result<()> {
        Ok(())
    }
    fn batch_commit(&mut self) -> std::io::Result<()> {
        Ok(())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
    fn close(&mut self) -> std::io::Result<()> {
        Ok(())
    }
    fn save_to(&mut self, path: &str) -> std::io::Result<()>;
    fn path(&self) -> Option<String> {
        None
    }
}

/// Pick the backend by file extension. Empty path → in-memory.
pub fn open_storage(path: &str, max_values: usize) -> Result<Box<dyn Storage>, std::io::Error> {
    if path.is_empty() {
        return Ok(Box::new(crate::storage_memory::MemoryStorage::new(
            max_values,
        )));
    }
    let lower = path.to_lowercase();
    if lower.ends_with(".db") || lower.ends_with(".sqlite") || lower.ends_with(".sqlite3") {
        return Ok(Box::new(crate::storage_sqlite::SqliteStorage::open(
            path, max_values,
        )?));
    }
    Ok(Box::new(crate::storage_json::JsonStorage::open(
        path, max_values,
    )?))
}

/// Coerce an arbitrary input into an Identifier. Helper used by Corpus.
pub fn coerce_identifier(s: &str) -> Result<Identifier, ParseError> {
    crate::parser::parse(s)
}
