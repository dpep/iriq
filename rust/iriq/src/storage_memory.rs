use crate::classifier::SegmentType;
use crate::cluster::Cluster;
use crate::identifier::Identifier;
use crate::position::Position;
use crate::position_stats::{PositionStats, DEFAULT_MAX_VALUES_PER_POSITION};
use crate::storage::Storage;
use std::collections::HashMap;

#[derive(Default)]
pub struct MemoryStorage {
    max_values: usize,
    host_counts: HashMap<String, usize>,
    path_length_counts: HashMap<usize, usize>,
    raw_shape_counts: HashMap<String, usize>,
    fingerprint_counts: HashMap<String, usize>,

    position_stats: HashMap<Position, PositionStats>,
    position_keys: Vec<Position>,

    clusters: HashMap<String, Cluster>,
    cluster_keys: Vec<String>,

    observed_iris: Vec<String>,
    activated_recognizers: Vec<serde_json::Value>,
}

impl MemoryStorage {
    pub fn new(max_values: usize) -> Self {
        let cap = if max_values == 0 { DEFAULT_MAX_VALUES_PER_POSITION } else { max_values };
        MemoryStorage { max_values: cap, ..Default::default() }
    }
}

impl Storage for MemoryStorage {
    fn max_values(&self) -> usize {
        self.max_values
    }

    fn increment_host(&mut self, host: &str) {
        *self.host_counts.entry(host.to_string()).or_insert(0) += 1;
    }
    fn increment_path_length(&mut self, length: usize) {
        *self.path_length_counts.entry(length).or_insert(0) += 1;
    }
    fn increment_raw_shape(&mut self, shape: &str) {
        *self.raw_shape_counts.entry(shape.to_string()).or_insert(0) += 1;
    }
    fn increment_fingerprint(&mut self, shape: &str) {
        *self.fingerprint_counts.entry(shape.to_string()).or_insert(0) += 1;
    }

    fn observe_position(&mut self, pos: &Position, value: &str, t: SegmentType) {
        let max = self.max_values;
        if !self.position_stats.contains_key(pos) {
            self.position_stats.insert(pos.clone(), PositionStats::new(max));
            self.position_keys.push(pos.clone());
        }
        self.position_stats.get_mut(pos).unwrap().observe(value, t);
    }

    fn add_to_cluster(
        &mut self,
        key: &str,
        host: &str,
        scheme: &str,
        shape: &str,
        iri: &Identifier,
    ) {
        let max = self.max_values;
        if !self.clusters.contains_key(key) {
            self.clusters.insert(
                key.to_string(),
                Cluster::new(
                    key.to_string(),
                    host.to_string(),
                    scheme.to_string(),
                    shape.to_string(),
                    max,
                ),
            );
            self.cluster_keys.push(key.to_string());
        }
        self.clusters.get_mut(key).unwrap().add(iri);
    }

    fn host_counts(&self) -> HashMap<String, usize> {
        self.host_counts.clone()
    }
    fn for_each_host(&self, f: &mut dyn FnMut(&str, usize)) {
        for (k, v) in &self.host_counts {
            f(k, *v);
        }
    }
    fn for_each_raw_shape(&self, f: &mut dyn FnMut(&str, usize)) {
        for (k, v) in &self.raw_shape_counts {
            f(k, *v);
        }
    }
    fn for_each_fingerprint(&self, f: &mut dyn FnMut(&str, usize)) {
        for (k, v) in &self.fingerprint_counts {
            f(k, *v);
        }
    }
    fn path_length_counts(&self) -> HashMap<usize, usize> {
        self.path_length_counts.clone()
    }
    fn raw_shape_counts(&self) -> HashMap<String, usize> {
        self.raw_shape_counts.clone()
    }
    fn fingerprint_counts(&self) -> HashMap<String, usize> {
        self.fingerprint_counts.clone()
    }
    fn position_stats_for(&self, pos: &Position) -> Option<PositionStats> {
        self.position_stats.get(pos).cloned()
    }
    fn each_position_stats(&self, f: &mut dyn FnMut(&Position, &PositionStats)) {
        for k in &self.position_keys {
            if let Some(v) = self.position_stats.get(k) {
                f(k, v);
            }
        }
    }
    fn clusters(&self) -> Vec<Cluster> {
        self.cluster_keys
            .iter()
            .filter_map(|k| self.clusters.get(k).cloned())
            .collect()
    }
    fn cluster_for(&self, key: &str) -> Option<Cluster> {
        self.clusters.get(key).cloned()
    }
    fn cluster_size(&self) -> usize {
        self.clusters.len()
    }

    fn record_observation(&mut self, canonical: &str) {
        self.observed_iris.push(canonical.to_string());
    }
    fn each_observed_iri(&self, f: &mut dyn FnMut(&str)) {
        for c in &self.observed_iris {
            f(c);
        }
    }
    fn observed_iri_count(&self) -> usize {
        self.observed_iris.len()
    }
    fn clear_materialized_views(&mut self) {
        self.host_counts.clear();
        self.path_length_counts.clear();
        self.raw_shape_counts.clear();
        self.fingerprint_counts.clear();
        self.position_stats.clear();
        self.position_keys.clear();
        self.clusters.clear();
        self.cluster_keys.clear();
    }

    fn record_activated_recognizer(&mut self, dump: serde_json::Value) {
        let prefix = dump.get("prefix").and_then(|v| v.as_str()).map(String::from);
        if let Some(p) = &prefix {
            for existing in &mut self.activated_recognizers {
                if existing.get("prefix").and_then(|v| v.as_str()) == Some(p) {
                    *existing = dump;
                    return;
                }
            }
        }
        self.activated_recognizers.push(dump);
    }
    fn each_activated_recognizer(&self, f: &mut dyn FnMut(&serde_json::Value)) {
        for d in &self.activated_recognizers {
            f(d);
        }
    }
    fn activated_recognizer_count(&self) -> usize {
        self.activated_recognizers.len()
    }

    fn save_to(&mut self, path: &str) -> std::io::Result<()> {
        crate::storage_json::dump_memory_to_json(self, path)
    }
}

// Accessor used by storage_json dump path.
impl MemoryStorage {
    pub fn fingerprint_counts_ref(&self) -> &HashMap<String, usize> {
        &self.fingerprint_counts
    }
    pub fn raw_shape_counts_ref(&self) -> &HashMap<String, usize> {
        &self.raw_shape_counts
    }
    pub fn host_counts_ref(&self) -> &HashMap<String, usize> {
        &self.host_counts
    }
    pub fn path_length_counts_ref(&self) -> &HashMap<usize, usize> {
        &self.path_length_counts
    }
    pub fn position_keys(&self) -> &[Position] {
        &self.position_keys
    }
    pub fn position_stats_map(&self) -> &HashMap<Position, PositionStats> {
        &self.position_stats
    }
    pub fn cluster_keys(&self) -> &[String] {
        &self.cluster_keys
    }
    pub fn cluster_map(&self) -> &HashMap<String, Cluster> {
        &self.clusters
    }
    pub fn observed_iris(&self) -> &[String] {
        &self.observed_iris
    }
    pub fn activated_recognizers_ref(&self) -> &[serde_json::Value] {
        &self.activated_recognizers
    }

    // ── Load-path shims (used by JSON / SQLite restore) ────────────────
    pub fn set_max_values(&mut self, n: usize) {
        if n > 0 {
            self.max_values = n;
        }
    }
    pub fn insert_position_stats(&mut self, pos: Position, stats: PositionStats) {
        if !self.position_stats.contains_key(&pos) {
            self.position_keys.push(pos.clone());
        }
        self.position_stats.insert(pos, stats);
    }
    pub fn insert_cluster(&mut self, key: String, cluster: Cluster) {
        if !self.clusters.contains_key(&key) {
            self.cluster_keys.push(key.clone());
        }
        self.clusters.insert(key, cluster);
    }
}
