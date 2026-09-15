use crate::classifier::{SegmentClassifier, SegmentType};
use crate::cluster::Cluster;
use crate::errors::Result;
use crate::identifier::Identifier;
use crate::position::Position;
use crate::position_stats::PositionStats;
use std::collections::HashMap;
use std::path::Path;

/// Persistence layer behind a Corpus. Phase-2 ships Memory, JSON, and
/// SQLite (optional via feature). Backends update materialized views and
/// own the source-IRI log used by Reinfer. Every read and write reports
/// failure: a read that fails must never look like a corpus with no evidence.
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

    fn host_counts(&self) -> Result<HashMap<String, usize>>;
    fn path_length_counts(&self) -> Result<HashMap<usize, usize>>;
    fn raw_shape_counts(&self) -> Result<HashMap<String, usize>>;
    fn fingerprint_counts(&self) -> Result<HashMap<String, usize>>;
    fn each_position_stats(&self, f: &mut dyn FnMut(&Position, &PositionStats)) -> Result<()>;
    fn clusters(&self) -> Result<Vec<Cluster>>;
    fn cluster_for(&self, key: &str) -> Result<Option<Cluster>>;
    fn cluster_size(&self) -> Result<usize>;
    /// What classifying `value` at `pos` reads, without materializing every
    /// value tracked there.
    fn position_evidence(&self, pos: &Position, value: &str) -> Result<Option<PositionEvidence>>;
    /// One query param's stats — narrower than `cluster_for`, which loads the
    /// cluster's examples and per-segment counts too.
    fn param_stats_for(&self, cluster_key: &str, name: &str) -> Result<Option<PositionStats>>;

    fn record_observation(&mut self, canonical: &str) -> Result<()>;
    fn each_observed_iri(&self, f: &mut dyn FnMut(&str)) -> Result<()>;
    fn observed_iri_count(&self) -> Result<usize>;
    fn clear_materialized_views(&mut self) -> Result<()>;

    fn record_activated_recognizer(&mut self, dump: serde_json::Value) -> Result<()>;
    fn each_activated_recognizer(&self, f: &mut dyn FnMut(&serde_json::Value)) -> Result<()>;
    fn activated_recognizer_count(&self) -> Result<usize>;

    /// One backend transaction around many writes. SQLite turns
    /// O(observations) commits into one; Memory + JSON are no-ops. Returns
    /// whether another connection may have committed since this one's
    /// previous batch began, making anything read from storage before stale.
    fn batch_begin(&mut self) -> Result<bool> {
        Ok(false)
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

/// The slice of a position's stats that classifies one value.
#[derive(Debug, Clone, PartialEq, Default)]
pub(crate) struct PositionEvidence {
    pub total: usize,
    pub type_counts: HashMap<SegmentType, usize>,
    pub cardinality: usize,
    /// The probed value's count; `None` when it isn't tracked.
    pub value_count: Option<usize>,
}

impl PositionEvidence {
    pub fn from_stats(stats: &PositionStats, value: &str) -> Self {
        PositionEvidence {
            total: stats.total,
            type_counts: stats.type_counts.clone(),
            cardinality: stats.cardinality(),
            value_count: stats.value_counts.get(value).copied(),
        }
    }

    /// Same as `PositionStats::variable_fraction`.
    pub fn variable_fraction(&self, c: &SegmentClassifier) -> f64 {
        if self.total == 0 {
            return 0.0;
        }
        let v: usize = self
            .type_counts
            .iter()
            .filter(|(t, _)| c.variable(**t))
            .map(|(_, n)| *n)
            .sum();
        (v as f64) / (self.total as f64)
    }

    /// Same as `PositionStats::value_fraction` for the probed value.
    pub fn value_fraction(&self) -> f64 {
        if self.total == 0 {
            return 0.0;
        }
        (self.value_count.unwrap_or(0) as f64) / (self.total as f64)
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::parse;

    // Small enough that the value cap drops some values.
    const CAP: usize = 3;

    fn backends(name: &str) -> Vec<(&'static str, Box<dyn Storage>)> {
        let dir = std::env::temp_dir().join(format!("iriq-evidence-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        #[allow(unused_mut)]
        let mut all: Vec<(&'static str, Box<dyn Storage>)> = vec![
            (
                "memory",
                Box::new(crate::storage_memory::MemoryStorage::new(CAP)),
            ),
            (
                "json",
                Box::new(crate::storage_json::JsonStorage::open(&dir.join("c.json"), CAP).unwrap()),
            ),
        ];
        #[cfg(feature = "sqlite")]
        all.push((
            "sqlite",
            Box::new(crate::storage_sqlite::SqliteStorage::open(&dir.join("c.db"), CAP).unwrap()),
        ));
        all
    }

    #[test]
    fn narrow_reads_agree_with_the_full_reads_they_replace() {
        let pos = Position::path("x.com", "/teams");
        let huge = "1".repeat(400);
        let urls = [
            "https://x.com/teams/a?page=1&tab=a".to_string(),
            "https://x.com/teams/a?page=2&tab=b".to_string(),
            "https://x.com/teams/b?page=2&tab=c".to_string(),
            "https://x.com/teams/c?page=7&tab=d".to_string(),
            format!("https://x.com/teams/d?page={huge}&tab=a"),
        ];
        for (backend, mut s) in backends("agree") {
            for (value, ty) in [
                ("a", SegmentType::Literal),
                ("a", SegmentType::Literal),
                ("7", SegmentType::Integer),
                ("b-c", SegmentType::Slug),
                (huge.as_str(), SegmentType::Integer),
                ("7", SegmentType::Integer),
            ] {
                s.observe_position(&pos, value, ty).unwrap();
            }
            for url in &urls {
                let iri = parse(url).unwrap();
                s.add_to_cluster("k", "x.com", "https", "/teams/{team}", &iri)
                    .unwrap();
            }

            let unseen = Position::path("x.com", "/nowhere");
            for p in [&pos, &unseen] {
                let mut stats = None;
                s.each_position_stats(&mut |at, st| {
                    if at == p {
                        stats = Some(st.clone());
                    }
                })
                .unwrap();
                // Tracked, dropped at the cap, and never seen.
                for value in ["a", "7", huge.as_str(), "zzz"] {
                    let full = stats
                        .as_ref()
                        .map(|st| PositionEvidence::from_stats(st, value));
                    let narrow = s.position_evidence(p, value).unwrap();
                    assert_eq!(narrow, full, "{backend}: evidence for {value:?} at {p:?}");
                }
            }
            for (key, name) in [("k", "page"), ("k", "tab"), ("k", "nope"), ("nope", "page")] {
                let full = s
                    .cluster_for(key)
                    .unwrap()
                    .and_then(|c| c.param_stats.get(name).cloned());
                let narrow = s.param_stats_for(key, name).unwrap();
                assert_eq!(narrow, full, "{backend}: param {name:?} in {key:?}");
            }
        }
    }
}
