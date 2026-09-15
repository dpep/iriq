use crate::classifier::SegmentClassifier;
use crate::hints::derive_hints;
use crate::identifier::Identifier;
use crate::shape::{Shape, ShapeRenderOptions};

pub struct ClusterKey {
    pub key: String,
    pub host: String,
    pub scheme: String,
    pub shape: String,
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
        let key = format!("{}:{}:{}", iri.scheme, ns, final_shape);
        return ClusterKey {
            key: key.clone(),
            host: String::new(),
            scheme: iri.scheme.clone(),
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
