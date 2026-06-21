use crate::classifier::{SegmentClassifier, DEFAULT_CLASSIFIER};
use crate::cluster::{Cluster, SegmentPositionStat};
use crate::errors::ParseError;
use crate::hints::{derive_hints, SegmentHint};
use crate::identifier::Identifier;
use crate::parser::parse;
use crate::shape::{Shape, ShapeRenderOptions};
use std::collections::HashMap;

pub struct ClusterKey {
    pub key: String,
    pub host: String,
    pub scheme: String,
    pub shape: String,
}

pub fn cluster_key_for(
    iri: &Identifier,
    c: &SegmentClassifier,
    shape: Option<String>,
) -> ClusterKey {
    cluster_key_for_host(iri, c, shape, iri.host.clone())
}

pub fn cluster_key_for_host(
    iri: &Identifier,
    c: &SegmentClassifier,
    shape: Option<String>,
    host_override: String,
) -> ClusterKey {
    if iri.is_urn() {
        let (ns, value) = match iri.nss.split_once(':') {
            Some((ns, val)) => (ns.to_string(), val.to_string()),
            None => (iri.nss.clone(), String::new()),
        };
        let mut final_shape = String::new();
        if !value.is_empty() {
            final_shape = urn_value_shape(&ns, &value, c);
        }
        let key = format!("urn:{}:{}", ns, final_shape);
        return ClusterKey {
            key: key.clone(),
            host: String::new(),
            scheme: "urn".to_string(),
            shape: key,
        };
    }
    let shape = shape.unwrap_or_else(|| {
        Shape::from_segments(&iri.path_segments, Some(c)).render(ShapeRenderOptions::default())
    });
    let key = format!("{}://{}{}", iri.scheme, host_override, shape);
    ClusterKey {
        key,
        host: host_override,
        scheme: iri.scheme.clone(),
        shape,
    }
}

fn urn_value_shape(ns: &str, value: &str, c: &SegmentClassifier) -> String {
    let parts = vec![ns.to_string(), value.to_string()];
    let entries = derive_hints(&parts, c);
    let entry = entries.last().unwrap();
    if !entry.variable {
        return entry.value.clone();
    }
    if !entry.hint.is_empty() {
        return format!("{{{}}}", entry.hint);
    }
    format!("{{{}}}", entry.ty.as_str())
}

#[derive(Debug, Clone)]
pub struct ExplainEntry {
    pub hint: SegmentHint,
    pub stable: bool,
}

pub struct Clusterer {
    pub classifier: &'static SegmentClassifier,
    clusters: HashMap<String, Cluster>,
    keys: Vec<String>,
}

impl Clusterer {
    pub fn new() -> Self {
        Clusterer {
            classifier: &DEFAULT_CLASSIFIER,
            clusters: HashMap::new(),
            keys: Vec::new(),
        }
    }

    pub fn add(&mut self, input: &str, shape: Option<String>) -> Result<&Cluster, ParseError> {
        let iri = parse(input)?;
        let k = cluster_key_for(&iri, self.classifier, shape);
        if !self.clusters.contains_key(&k.key) {
            let cluster = Cluster::new(k.key.clone(), k.host, k.scheme, k.shape.clone(), 0);
            self.clusters.insert(k.key.clone(), cluster);
            self.keys.push(k.key.clone());
        }
        let c = self.clusters.get_mut(&k.key).unwrap();
        c.add(&iri);
        Ok(self.clusters.get(&k.key).unwrap())
    }

    pub fn clusters(&self) -> Vec<&Cluster> {
        self.keys
            .iter()
            .filter_map(|k| self.clusters.get(k))
            .collect()
    }

    pub fn size(&self) -> usize {
        self.clusters.len()
    }

    pub fn explain(&self, input: &str) -> Result<Vec<ExplainEntry>, ParseError> {
        let iri = parse(input)?;
        let k = cluster_key_for(&iri, self.classifier, None);
        let stats: Vec<SegmentPositionStat> = self
            .clusters
            .get(&k.key)
            .map(|c| c.segment_stats())
            .unwrap_or_default();
        let hinted = derive_hints(&iri.path_segments, self.classifier);
        Ok(hinted
            .into_iter()
            .enumerate()
            .map(|(i, mut entry)| {
                let stable = i < stats.len() && stats[i].stable;
                entry.variable = !stable && entry.variable;
                ExplainEntry {
                    hint: entry,
                    stable,
                }
            })
            .collect())
    }
}

impl Default for Clusterer {
    fn default() -> Self {
        Self::new()
    }
}
