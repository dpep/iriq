use crate::classifier::{
    canonical_currency, canonical_date, display_type, param_name_hint, SegmentClassifier,
    SegmentType, DEFAULT_CLASSIFIER,
};
use crate::errors::ParseError;
use crate::hints::derive_hints;
use crate::identifier::Identifier;
use crate::parser::parse;
use crate::path_shape::PathShape;

pub trait NormalizationEvidence: Send + Sync {
    fn render_path(&self, iri: &Identifier, c: &SegmentClassifier, hints: bool) -> String;
    fn render_query(&self, iri: &Identifier, c: &SegmentClassifier) -> String;
}

pub struct NullEvidence;

impl NormalizationEvidence for NullEvidence {
    fn render_path(&self, iri: &Identifier, c: &SegmentClassifier, hints: bool) -> String {
        let mut ps = PathShape::new();
        ps.classifier = c;
        ps.hints = hints;
        ps.canonical_dates = true;
        ps.canonical_currencies = true;
        ps.for_segments(&iri.path_segments)
    }

    fn render_query(&self, iri: &Identifier, c: &SegmentClassifier) -> String {
        shape_query(iri, c)
    }
}

pub fn normalize(input: &str) -> Result<String, ParseError> {
    normalize_with(input, &DEFAULT_CLASSIFIER, true)
}

pub fn normalize_with(
    input: &str,
    c: &SegmentClassifier,
    hints: bool,
) -> Result<String, ParseError> {
    let iri = parse(input)?;
    Ok(normalize_identifier(&iri, c, hints))
}

pub fn normalize_identifier(iri: &Identifier, c: &SegmentClassifier, hints: bool) -> String {
    normalize_identifier_with_evidence(iri, c, hints, &NullEvidence)
}

pub fn normalize_identifier_with_evidence(
    iri: &Identifier,
    c: &SegmentClassifier,
    hints: bool,
    ev: &dyn NormalizationEvidence,
) -> String {
    if iri.is_urn() {
        return normalize_urn(iri, c, hints);
    }
    let mut s = String::new();
    if !iri.scheme.is_empty() {
        s.push_str(&iri.scheme);
        s.push_str("://");
    }
    if !iri.host.is_empty() {
        s.push_str(&iri.host);
    }
    if iri.port != 0 {
        s.push(':');
        s.push_str(&iri.port.to_string());
    }
    s.push_str(&ev.render_path(iri, c, hints));
    if !iri.query_params.is_empty() {
        s.push('?');
        s.push_str(&ev.render_query(iri, c));
    }
    s
}

fn normalize_urn(iri: &Identifier, c: &SegmentClassifier, hints: bool) -> String {
    if !(iri.scheme == "urn" && !iri.nss.is_empty() && iri.nss.contains(':')) {
        return iri.canonical();
    }
    let (ns, value) = iri.nss.split_once(':').unwrap();
    let entries = derive_hints(&[ns.to_string(), value.to_string()], c);
    let entry = entries.last().unwrap();
    let shaped = if entry.ty == SegmentType::Date {
        if let Some(canon) = canonical_date(&entry.value) {
            canon
        } else {
            placeholder(entry, hints)
        }
    } else if entry.ty == SegmentType::Currency {
        if let Some(canon) = canonical_currency(&entry.value) {
            canon
        } else {
            placeholder(entry, hints)
        }
    } else if entry.variable {
        placeholder(entry, hints)
    } else {
        entry.value.clone()
    };
    format!("urn:{}:{}", ns, shaped)
}

fn placeholder(entry: &crate::hints::SegmentHint, hints: bool) -> String {
    let p = if hints && !entry.hint.is_empty() {
        entry.hint.clone()
    } else {
        display_type(entry.ty).to_string()
    };
    format!("{{{}}}", p)
}

fn shape_query(iri: &Identifier, c: &SegmentClassifier) -> String {
    let mut keys = iri.query_params.keys();
    keys.sort();
    let mut parts: Vec<String> = Vec::with_capacity(keys.len());
    for k in keys {
        let v = iri.query_params.get(&k).unwrap_or("").to_string();
        let mut t = c.classify(&v);
        if let Some(h) = param_name_hint(&k, t) {
            t = h;
        }
        let shaped = if t == SegmentType::Date {
            if let Some(canon) = canonical_date(&v) {
                canon
            } else {
                format!("{{{}}}", display_type(t))
            }
        } else if t == SegmentType::Currency {
            if let Some(canon) = canonical_currency(&v) {
                canon
            } else {
                format!("{{{}}}", display_type(t))
            }
        } else if c.variable(t) {
            format!("{{{}}}", display_type(t))
        } else {
            v.clone()
        };
        parts.push(format!("{}={}", k, shaped));
    }
    parts.join("&")
}
