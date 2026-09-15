use crate::classifier::SegmentType;
use crate::cluster::Cluster;
use crate::errors::{Error, Result};
use crate::identifier::Identifier;
use crate::parser::parse;
use crate::position::{Position, PositionScope};
use crate::position_stats::{PositionStats, DEFAULT_MAX_VALUES_PER_POSITION};
use crate::storage::{PositionEvidence, Storage};
use crate::storage_memory::MemoryStorage;
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// JSON-backed corpus storage. Wraps a `MemoryStorage` with load/save
/// against a file. On-disk format matches Ruby + Go byte-for-byte
/// (modulo serde key-ordering inside maps, which neither runtime
/// preserves through json marshal/unmarshal).
pub struct JsonStorage {
    inner: MemoryStorage,
    path: PathBuf,
}

impl JsonStorage {
    pub fn open(path: &Path, max_values: usize) -> Result<Self> {
        let mut s = JsonStorage {
            inner: MemoryStorage::new(max_values),
            path: path.to_path_buf(),
        };
        match std::fs::read(path) {
            Ok(data) if data.is_empty() => {}
            Ok(data) => load_memory_from_json(&mut s.inner, &data, path)?,
            // A corpus that doesn't exist yet is created on save, so fail now
            // (naming it) if there is nowhere to create it.
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let dir = path
                    .parent()
                    .filter(|d| !d.as_os_str().is_empty())
                    .unwrap_or(Path::new("."));
                std::fs::metadata(dir).map_err(|e| Error::io(path, e))?;
            }
            Err(e) => return Err(Error::io(path, e)),
        }
        Ok(s)
    }
}

impl Storage for JsonStorage {
    fn max_values(&self) -> usize {
        self.inner.max_values()
    }

    fn increment_host(&mut self, host: &str) -> Result<()> {
        self.inner.increment_host(host)
    }
    fn increment_path_length(&mut self, length: usize) -> Result<()> {
        self.inner.increment_path_length(length)
    }
    fn increment_raw_shape(&mut self, shape: &str) -> Result<()> {
        self.inner.increment_raw_shape(shape)
    }
    fn increment_fingerprint(&mut self, shape: &str) -> Result<()> {
        self.inner.increment_fingerprint(shape)
    }
    fn observe_position(&mut self, pos: &Position, value: &str, t: SegmentType) -> Result<()> {
        self.inner.observe_position(pos, value, t)
    }
    fn add_to_cluster(
        &mut self,
        key: &str,
        host: &str,
        scheme: &str,
        shape: &str,
        iri: &Identifier,
    ) -> Result<()> {
        self.inner.add_to_cluster(key, host, scheme, shape, iri)
    }

    fn host_counts(&self) -> Result<HashMap<String, usize>> {
        self.inner.host_counts()
    }
    fn path_length_counts(&self) -> Result<HashMap<usize, usize>> {
        self.inner.path_length_counts()
    }
    fn raw_shape_counts(&self) -> Result<HashMap<String, usize>> {
        self.inner.raw_shape_counts()
    }
    fn fingerprint_counts(&self) -> Result<HashMap<String, usize>> {
        self.inner.fingerprint_counts()
    }
    fn each_position_stats(&self, f: &mut dyn FnMut(&Position, &PositionStats)) -> Result<()> {
        self.inner.each_position_stats(f)
    }
    fn clusters(&self) -> Result<Vec<Cluster>> {
        self.inner.clusters()
    }
    fn cluster_for(&self, key: &str) -> Result<Option<Cluster>> {
        self.inner.cluster_for(key)
    }
    fn cluster_size(&self) -> Result<usize> {
        self.inner.cluster_size()
    }
    fn position_evidence(&self, pos: &Position, value: &str) -> Result<Option<PositionEvidence>> {
        self.inner.position_evidence(pos, value)
    }
    fn param_stats_for(&self, cluster_key: &str, name: &str) -> Result<Option<PositionStats>> {
        self.inner.param_stats_for(cluster_key, name)
    }
    fn record_observation(&mut self, canonical: &str) -> Result<()> {
        self.inner.record_observation(canonical)
    }
    fn each_observed_iri(&self, f: &mut dyn FnMut(&str)) -> Result<()> {
        self.inner.each_observed_iri(f)
    }
    fn observed_iri_count(&self) -> Result<usize> {
        self.inner.observed_iri_count()
    }
    fn clear_materialized_views(&mut self) -> Result<()> {
        self.inner.clear_materialized_views()
    }
    fn record_activated_recognizer(&mut self, dump: Value) -> Result<()> {
        self.inner.record_activated_recognizer(dump)
    }
    fn each_activated_recognizer(&self, f: &mut dyn FnMut(&Value)) -> Result<()> {
        self.inner.each_activated_recognizer(f)
    }
    fn activated_recognizer_count(&self) -> Result<usize> {
        self.inner.activated_recognizer_count()
    }

    fn flush(&mut self) -> Result<()> {
        dump_memory_to_json(&self.inner, &self.path)
    }
    fn save_to(&mut self, path: &Path) -> Result<()> {
        dump_memory_to_json(&self.inner, path)
    }
    fn path(&self) -> Option<&Path> {
        Some(&self.path)
    }
}

pub fn dump_memory_to_json(m: &MemoryStorage, path: &Path) -> Result<()> {
    let mut root = Map::new();
    root.insert(
        "host_counts".to_string(),
        map_str_usize_to_value(m.host_counts_ref()),
    );
    let plc: HashMap<String, usize> = m
        .path_length_counts_ref()
        .iter()
        .map(|(k, v)| (k.to_string(), *v))
        .collect();
    root.insert(
        "path_length_counts".to_string(),
        map_str_usize_to_value(&plc),
    );
    root.insert(
        "raw_shape_counts".to_string(),
        map_str_usize_to_value(m.raw_shape_counts_ref()),
    );
    root.insert(
        "fingerprint_counts".to_string(),
        map_str_usize_to_value(m.fingerprint_counts_ref()),
    );
    root.insert(
        "max_values_per_position".to_string(),
        Value::Number((m.max_values() as u64).into()),
    );

    let mut ps_arr = Vec::new();
    for k in m.position_keys() {
        let stats = m.position_stats_map().get(k).unwrap();
        let mut pos_m = Map::new();
        pos_m.insert("host".to_string(), Value::String(k.host.clone()));
        pos_m.insert(
            "scope".to_string(),
            Value::String(k.scope.as_str().to_string()),
        );
        pos_m.insert("locator".to_string(), Value::String(k.locator.clone()));
        let mut entry = Map::new();
        entry.insert("position".to_string(), Value::Object(pos_m));
        entry.insert("stats".to_string(), position_stats_to_value(stats));
        ps_arr.push(Value::Object(entry));
    }
    root.insert("position_stats".to_string(), Value::Array(ps_arr));

    let mut clu_map = Map::new();
    for key in m.cluster_keys() {
        let c = m.cluster_map().get(key).unwrap();
        clu_map.insert(key.clone(), cluster_to_value(c));
    }
    let mut clusterer = Map::new();
    clusterer.insert("clusters".to_string(), Value::Object(clu_map));
    root.insert("clusterer".to_string(), Value::Object(clusterer));

    let observed: Vec<Value> = m
        .observed_iris()
        .iter()
        .map(|s| Value::String(s.clone()))
        .collect();
    root.insert("observed_iris".to_string(), Value::Array(observed));

    let activated: Vec<Value> = m.activated_recognizers_ref().to_vec();
    root.insert("activated_recognizers".to_string(), Value::Array(activated));

    let data = serde_json::to_string(&Value::Object(root))
        .map_err(|e| Error::io(path, std::io::Error::other(e)))?;
    // A temp name per write: concurrent writers sharing `<path>.tmp` rename
    // each other's file away and fail. The last rename still wins.
    static WRITES: AtomicU64 = AtomicU64::new(0);
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(format!(
        ".{}.{}.tmp",
        std::process::id(),
        WRITES.fetch_add(1, Ordering::Relaxed)
    ));
    let write = || -> std::io::Result<()> {
        std::fs::File::create(&tmp)?.write_all(data.as_bytes())?;
        std::fs::rename(&tmp, path)
    };
    write().map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        Error::io(path, e)
    })
}

/// The top-level keys a corpus dump writes (Ruby's `to_dump` writes the same).
const CORPUS_KEYS: [&str; 9] = [
    "host_counts",
    "path_length_counts",
    "raw_shape_counts",
    "fingerprint_counts",
    "max_values_per_position",
    "position_stats",
    "clusterer",
    "observed_iris",
    "activated_recognizers",
];

fn position_stats_to_value(s: &PositionStats) -> Value {
    let mut o = Map::new();
    o.insert(
        "value_counts".to_string(),
        map_str_usize_to_value(&s.value_counts),
    );
    let tc: HashMap<String, usize> = s
        .type_counts
        .iter()
        .map(|(t, n)| (t.as_str().to_string(), *n))
        .collect();
    o.insert("type_counts".to_string(), map_str_usize_to_value(&tc));
    o.insert("total".to_string(), Value::Number((s.total as u64).into()));
    o.insert(
        "max_values".to_string(),
        Value::Number((s.max_values as u64).into()),
    );
    Value::Object(o)
}

fn cluster_to_value(c: &Cluster) -> Value {
    let mut o = Map::new();
    o.insert("key".to_string(), Value::String(c.key.clone()));
    o.insert("host".to_string(), Value::String(c.host.clone()));
    o.insert("scheme".to_string(), Value::String(c.scheme.clone()));
    o.insert("shape".to_string(), Value::String(c.shape.clone()));
    o.insert("count".to_string(), Value::Number((c.count as u64).into()));
    let examples: Vec<Value> = c
        .examples
        .iter()
        .map(|e| Value::String(e.canonical()))
        .collect();
    o.insert("examples".to_string(), Value::Array(examples));
    let seg: Vec<Value> = c
        .segment_counts
        .iter()
        .map(map_str_usize_to_value)
        .collect();
    o.insert("segment_counts".to_string(), Value::Array(seg));
    let mut params = Map::new();
    for (name, stats) in &c.param_stats {
        params.insert(name.clone(), position_stats_to_value(stats));
    }
    o.insert("param_stats".to_string(), Value::Object(params));
    Value::Object(o)
}

fn map_str_usize_to_value(m: &HashMap<String, usize>) -> Value {
    let mut o = Map::new();
    for (k, v) in m {
        o.insert(k.clone(), Value::Number((*v as u64).into()));
    }
    Value::Object(o)
}

pub fn load_memory_from_json(m: &mut MemoryStorage, data: &[u8], path: &Path) -> Result<()> {
    // Reasons match Ruby's Storage::Json word for word.
    const NOT_A_CORPUS: &str = "not an iriq corpus (no corpus keys at the top level)";
    let root: Value =
        serde_json::from_slice(data).map_err(|_| Error::corrupt(path, "not valid JSON"))?;
    let obj = root
        .as_object()
        .ok_or_else(|| Error::corrupt(path, NOT_A_CORPUS))?;
    // `{}` is an empty corpus; any other object must be one we wrote, or a
    // save would overwrite someone else's JSON file.
    if !obj.is_empty() && !CORPUS_KEYS.iter().any(|k| obj.contains_key(*k)) {
        return Err(Error::corrupt(path, NOT_A_CORPUS));
    }

    // Note: MemoryStorage owns the inner maps; we use the trait methods that
    // increment one-by-one (since there's no direct setter). For loading,
    // we want bulk insert — we use a low-level path through observe_position /
    // add_to_cluster via private accessors. The simplest approach: clear
    // then increment_X repeatedly.

    if let Some(v) = obj.get("max_values_per_position").and_then(|v| v.as_u64()) {
        // MaxValues is set at construction. The MemoryStorage struct has
        // it private; load semantics differ from observe path. We surface a
        // `set_max_values` shim on MemoryStorage.
        m.set_max_values(v as usize);
    }
    if let Some(map) = obj.get("host_counts").and_then(|v| v.as_object()) {
        for (k, v) in map {
            if let Some(n) = v.as_u64() {
                for _ in 0..n {
                    m.increment_host(k)?;
                }
            }
        }
    }
    if let Some(map) = obj.get("raw_shape_counts").and_then(|v| v.as_object()) {
        for (k, v) in map {
            if let Some(n) = v.as_u64() {
                for _ in 0..n {
                    m.increment_raw_shape(k)?;
                }
            }
        }
    }
    if let Some(map) = obj.get("fingerprint_counts").and_then(|v| v.as_object()) {
        for (k, v) in map {
            if let Some(n) = v.as_u64() {
                for _ in 0..n {
                    m.increment_fingerprint(k)?;
                }
            }
        }
    }
    if let Some(map) = obj.get("path_length_counts").and_then(|v| v.as_object()) {
        for (k, v) in map {
            let len: usize = k
                .parse()
                .map_err(|e: std::num::ParseIntError| Error::corrupt(path, e.to_string()))?;
            if let Some(n) = v.as_u64() {
                for _ in 0..n {
                    m.increment_path_length(len)?;
                }
            }
        }
    }

    // PositionStats — restore directly via raw setter to preserve totals
    // and per-type counts (the increment path through `observe_position`
    // would re-classify which is wrong on a load).
    if let Some(arr) = obj.get("position_stats").and_then(|v| v.as_array()) {
        for entry in arr {
            let pos_obj = entry.get("position").and_then(|v| v.as_object());
            let stats_obj = entry.get("stats").and_then(|v| v.as_object());
            if pos_obj.is_none() || stats_obj.is_none() {
                continue;
            }
            let po = pos_obj.unwrap();
            let host = po
                .get("host")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let scope = match po.get("scope").and_then(|v| v.as_str()).unwrap_or("path") {
                "query" => PositionScope::Query,
                _ => PositionScope::Path,
            };
            let locator = po
                .get("locator")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let pos = Position {
                host,
                scope,
                locator,
            };
            let stats = parse_position_stats(stats_obj.unwrap());
            m.insert_position_stats(pos, stats);
        }
    }

    if let Some(clu) = obj.get("clusterer").and_then(|v| v.as_object()) {
        if let Some(clusters) = clu.get("clusters").and_then(|v| v.as_object()) {
            for (key, cobj) in clusters {
                let cobj = cobj
                    .as_object()
                    .ok_or_else(|| Error::corrupt(path, "cluster value not an object"))?;
                let host = cobj
                    .get("host")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let scheme = cobj
                    .get("scheme")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let shape = cobj
                    .get("shape")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let count = cobj.get("count").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
                let mut cluster = Cluster::new(key.clone(), host, scheme, shape, m.max_values());
                cluster.count = count;
                if let Some(ex) = cobj.get("examples").and_then(|v| v.as_array()) {
                    for e in ex {
                        if let Some(s) = e.as_str() {
                            if let Ok(iri) = parse(s) {
                                cluster.register_example_key(iri.canonical());
                                cluster.examples.push(std::sync::Arc::new(iri));
                            }
                        }
                    }
                }
                if let Some(seg) = cobj.get("segment_counts").and_then(|v| v.as_array()) {
                    for sm in seg {
                        let mut map = HashMap::new();
                        if let Some(o) = sm.as_object() {
                            for (k, v) in o {
                                if let Some(n) = v.as_u64() {
                                    map.insert(k.clone(), n as usize);
                                }
                            }
                        }
                        cluster.segment_counts.push(map);
                    }
                }
                if let Some(params) = cobj.get("param_stats").and_then(|v| v.as_object()) {
                    for (name, sv) in params {
                        if let Some(so) = sv.as_object() {
                            cluster
                                .param_stats
                                .insert(name.clone(), parse_position_stats(so));
                        }
                    }
                }
                m.insert_cluster(key.clone(), cluster);
            }
        }
    }

    if let Some(arr) = obj.get("observed_iris").and_then(|v| v.as_array()) {
        for s in arr {
            if let Some(s) = s.as_str() {
                m.record_observation(s)?;
            }
        }
        // record_observation also appends to the log; we want to set
        // the log directly. Easier: clear then push raw. We use a shim.
        // Actually each record_observation pushes one — that's correct.
        // But we don't want each push to also re-fire any side effects.
        // MemoryStorage.record_observation only appends to observed_iris,
        // so the loop above is fine.
    }
    if let Some(arr) = obj.get("activated_recognizers").and_then(|v| v.as_array()) {
        for v in arr {
            m.record_activated_recognizer(v.clone())?;
        }
    }
    Ok(())
}

fn parse_position_stats(obj: &Map<String, Value>) -> PositionStats {
    let max = obj.get("max_values").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
    let mut ps = PositionStats::new(if max == 0 {
        DEFAULT_MAX_VALUES_PER_POSITION
    } else {
        max
    });
    ps.total = obj.get("total").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
    if let Some(vc) = obj.get("value_counts").and_then(|v| v.as_object()) {
        for (k, v) in vc {
            if let Some(n) = v.as_u64() {
                ps.value_counts.insert(k.clone(), n as usize);
            }
        }
    }
    if let Some(tc) = obj.get("type_counts").and_then(|v| v.as_object()) {
        for (k, v) in tc {
            if let Some(n) = v.as_u64() {
                ps.type_counts
                    .insert(crate::classifier::segment_type_from_name(k), n as usize);
            }
        }
    }
    rebuild_numeric_stats(&mut ps);
    ps
}

/// Rebuild a reloaded position's numeric range from its value counts, by the
/// rule `PositionStats::observe` applies live: only integer/float positions
/// have a range, and a value that overflows to ±inf counts as an observation
/// but never enters min/max/avg. Lossy at the value cap: values dropped there
/// are gone from the range too.
pub(crate) fn rebuild_numeric_stats(stats: &mut PositionStats) {
    let numeric = [SegmentType::Integer, SegmentType::Float]
        .iter()
        .any(|t| stats.type_counts.get(t).is_some_and(|&n| n > 0));
    if !numeric {
        return;
    }
    for (value, &count) in &stats.value_counts {
        let Some(num) = value.parse::<f64>().ok().filter(|n| n.is_finite()) else {
            continue;
        };
        for _ in 0..count {
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
