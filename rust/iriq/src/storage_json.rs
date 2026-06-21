use crate::classifier::SegmentType;
use crate::cluster::Cluster;
use crate::identifier::Identifier;
use crate::parser::parse;
use crate::position::{Position, PositionScope};
use crate::position_stats::{PositionStats, DEFAULT_MAX_VALUES_PER_POSITION};
use crate::storage::Storage;
use crate::storage_memory::MemoryStorage;
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::io::Write;

/// JSON-backed corpus storage. Wraps a `MemoryStorage` with load/save
/// against a file. On-disk format matches Ruby + Go byte-for-byte
/// (modulo serde key-ordering inside maps, which neither runtime
/// preserves through json marshal/unmarshal).
pub struct JsonStorage {
    inner: MemoryStorage,
    path: String,
}

impl JsonStorage {
    pub fn open(path: &str, max_values: usize) -> std::io::Result<Self> {
        let mut s = JsonStorage {
            inner: MemoryStorage::new(max_values),
            path: path.to_string(),
        };
        if let Ok(meta) = std::fs::metadata(path) {
            if meta.len() > 0 {
                let data = std::fs::read(path)?;
                load_memory_from_json(&mut s.inner, &data).map_err(io_err)?;
            }
        }
        Ok(s)
    }
}

fn io_err<E: std::fmt::Display>(e: E) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string())
}

impl Storage for JsonStorage {
    fn max_values(&self) -> usize {
        self.inner.max_values()
    }

    fn increment_host(&mut self, host: &str) {
        self.inner.increment_host(host);
    }
    fn increment_path_length(&mut self, length: usize) {
        self.inner.increment_path_length(length);
    }
    fn increment_raw_shape(&mut self, shape: &str) {
        self.inner.increment_raw_shape(shape);
    }
    fn increment_fingerprint(&mut self, shape: &str) {
        self.inner.increment_fingerprint(shape);
    }
    fn observe_position(&mut self, pos: &Position, value: &str, t: SegmentType) {
        self.inner.observe_position(pos, value, t);
    }
    fn add_to_cluster(
        &mut self,
        key: &str,
        host: &str,
        scheme: &str,
        shape: &str,
        iri: &Identifier,
    ) {
        self.inner.add_to_cluster(key, host, scheme, shape, iri);
    }

    fn host_counts(&self) -> HashMap<String, usize> {
        self.inner.host_counts()
    }
    fn path_length_counts(&self) -> HashMap<usize, usize> {
        self.inner.path_length_counts()
    }
    fn raw_shape_counts(&self) -> HashMap<String, usize> {
        self.inner.raw_shape_counts()
    }
    fn fingerprint_counts(&self) -> HashMap<String, usize> {
        self.inner.fingerprint_counts()
    }
    fn position_stats_for(&self, pos: &Position) -> Option<PositionStats> {
        self.inner.position_stats_for(pos)
    }
    fn each_position_stats(&self, f: &mut dyn FnMut(&Position, &PositionStats)) {
        self.inner.each_position_stats(f);
    }
    fn clusters(&self) -> Vec<Cluster> {
        self.inner.clusters()
    }
    fn cluster_for(&self, key: &str) -> Option<Cluster> {
        self.inner.cluster_for(key)
    }
    fn cluster_size(&self) -> usize {
        self.inner.cluster_size()
    }
    fn record_observation(&mut self, canonical: &str) {
        self.inner.record_observation(canonical);
    }
    fn each_observed_iri(&self, f: &mut dyn FnMut(&str)) {
        self.inner.each_observed_iri(f);
    }
    fn observed_iri_count(&self) -> usize {
        self.inner.observed_iri_count()
    }
    fn clear_materialized_views(&mut self) {
        self.inner.clear_materialized_views();
    }
    fn record_activated_recognizer(&mut self, dump: Value) {
        self.inner.record_activated_recognizer(dump);
    }
    fn each_activated_recognizer(&self, f: &mut dyn FnMut(&Value)) {
        self.inner.each_activated_recognizer(f);
    }
    fn activated_recognizer_count(&self) -> usize {
        self.inner.activated_recognizer_count()
    }

    fn flush(&mut self) -> std::io::Result<()> {
        dump_memory_to_json(&self.inner, &self.path)
    }
    fn save_to(&mut self, path: &str) -> std::io::Result<()> {
        dump_memory_to_json(&self.inner, path)
    }
    fn path(&self) -> Option<String> {
        Some(self.path.clone())
    }
}

pub fn dump_memory_to_json(m: &MemoryStorage, path: &str) -> std::io::Result<()> {
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

    let data = serde_json::to_string(&Value::Object(root)).map_err(io_err)?;
    let tmp = format!("{}.tmp", path);
    {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(data.as_bytes())?;
    }
    std::fs::rename(&tmp, path)
}

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

pub fn load_memory_from_json(m: &mut MemoryStorage, data: &[u8]) -> Result<(), String> {
    let root: Value = serde_json::from_slice(data).map_err(|e| e.to_string())?;
    let obj = root.as_object().ok_or("root not an object")?;

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
                    m.increment_host(k);
                }
            }
        }
    }
    if let Some(map) = obj.get("raw_shape_counts").and_then(|v| v.as_object()) {
        for (k, v) in map {
            if let Some(n) = v.as_u64() {
                for _ in 0..n {
                    m.increment_raw_shape(k);
                }
            }
        }
    }
    if let Some(map) = obj.get("fingerprint_counts").and_then(|v| v.as_object()) {
        for (k, v) in map {
            if let Some(n) = v.as_u64() {
                for _ in 0..n {
                    m.increment_fingerprint(k);
                }
            }
        }
    }
    if let Some(map) = obj.get("path_length_counts").and_then(|v| v.as_object()) {
        for (k, v) in map {
            let len: usize = k
                .parse()
                .map_err(|e: std::num::ParseIntError| e.to_string())?;
            if let Some(n) = v.as_u64() {
                for _ in 0..n {
                    m.increment_path_length(len);
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
                let cobj = cobj.as_object().ok_or("cluster value not an object")?;
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
                m.record_observation(s);
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
            m.record_activated_recognizer(v.clone());
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
                if let Some(ty) = parse_segment_type(k) {
                    ps.type_counts.insert(ty, n as usize);
                }
            }
        }
    }
    // Recompute numeric stats from value_counts to keep type-promotion
    // logic working post-load. Iterates value_counts × types.
    // (Lossy with cap: numeric_sum may drift if values were dropped at
    // the cap — same caveat the Go side has.)
    for (v, n) in &ps.value_counts {
        if let Ok(num) = v.parse::<f64>() {
            // Only count as numeric if integer / float type was tracked.
            let was_numeric = ps
                .type_counts
                .get(&SegmentType::Integer)
                .copied()
                .unwrap_or(0)
                > 0
                || ps
                    .type_counts
                    .get(&SegmentType::Float)
                    .copied()
                    .unwrap_or(0)
                    > 0;
            if was_numeric {
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
    ps
}

fn parse_segment_type(s: &str) -> Option<SegmentType> {
    use SegmentType::*;
    Some(match s {
        "literal" => Literal,
        "integer" => Integer,
        "float" => Float,
        "number" => Number,
        "uuid" => Uuid,
        "date" => Date,
        "timestamp" => Timestamp,
        "hash" => Hash,
        "slug" => Slug,
        "ipv4" => Ipv4,
        "ipv6" => Ipv6,
        "url" => Url,
        "email" => Email,
        "boolean" => Boolean,
        "version" => Version,
        "locale" => Locale,
        "currency" => Currency,
        "phone" => Phone,
        "jwt" => Jwt,
        "mime" => Mime,
        "file" => File,
        "color" => Color,
        "coordinate" => Coordinate,
        "country" => Country,
        "base64" => Base64,
        "year" => Year,
        "http_status" => HttpStatus,
        "enum" => Enum,
        "opaque_id" => OpaqueId,
        _ => return None,
    })
}
