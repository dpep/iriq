use crate::classifier::{
    canonical_currency, canonical_date, display_type, param_name_hint, SegmentClassifier,
    SegmentType, DEFAULT_CLASSIFIER,
};
use crate::errors::ParseError;
use crate::hints::derive_hints;
use crate::identifier::Identifier;
use crate::parser::parse;
use crate::path_shape::PathShape;
use std::convert::Infallible;

pub trait NormalizationEvidence {
    /// What a failed evidence read reports.
    type Error;
    fn render_path(
        &self,
        iri: &Identifier,
        c: &SegmentClassifier,
        hints: bool,
    ) -> Result<String, Self::Error>;
    fn render_query(&self, iri: &Identifier, c: &SegmentClassifier) -> Result<String, Self::Error>;
}

pub struct NullEvidence;

impl NormalizationEvidence for NullEvidence {
    type Error = Infallible;

    fn render_path(
        &self,
        iri: &Identifier,
        c: &SegmentClassifier,
        hints: bool,
    ) -> Result<String, Infallible> {
        let mut ps = PathShape::new();
        ps.classifier = c;
        ps.hints = hints;
        ps.canonical_dates = true;
        ps.canonical_currencies = true;
        Ok(ps.for_segments(&iri.path_segments))
    }

    fn render_query(&self, iri: &Identifier, c: &SegmentClassifier) -> Result<String, Infallible> {
        Ok(shape_query(iri, c))
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
    Ok(normalize_identifier_with(&iri, c, hints))
}

/// Normalize an already-parsed IRI (see [`normalize`]). `hints: false`
/// renders bare type placeholders (`{integer}`) instead of hinted names
/// (`{user_id}`).
pub fn normalize_identifier(iri: &Identifier, hints: bool) -> String {
    normalize_identifier_with(iri, &DEFAULT_CLASSIFIER, hints)
}

pub(crate) fn normalize_identifier_with(
    iri: &Identifier,
    c: &SegmentClassifier,
    hints: bool,
) -> String {
    let Ok(s) = normalize_identifier_with_evidence(iri, c, hints, &NullEvidence);
    s
}

pub fn normalize_identifier_with_evidence<E: NormalizationEvidence>(
    iri: &Identifier,
    c: &SegmentClassifier,
    hints: bool,
    ev: &E,
) -> Result<String, E::Error> {
    if iri.is_urn() {
        return Ok(normalize_urn(iri, c, hints));
    }
    let mut s = String::new();
    if !iri.scheme.is_empty() {
        s.push_str(&iri.scheme);
        s.push_str("://");
    }
    if !iri.host.is_empty() {
        s.push_str(&iri.host);
    }
    if let Some(port) = iri.port {
        s.push(':');
        s.push_str(&port.to_string());
    }
    s.push_str(&ev.render_path(iri, c, hints)?);
    if !iri.query_params.is_empty() {
        s.push('?');
        s.push_str(&ev.render_query(iri, c)?);
    }
    Ok(s)
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
        display_type(&entry.ty).to_string()
    };
    format!("{{{}}}", p)
}

fn shape_query(iri: &Identifier, c: &SegmentClassifier) -> String {
    let mut keys = iri.query_params.keys();
    keys.sort();
    let mut parts: Vec<String> = Vec::with_capacity(keys.len());
    for k in keys {
        let v = iri.query_params.get(&k).unwrap_or("");
        parts.push(format!("{}={}", k, render_param(&k, v, c)));
    }
    parts.join("&")
}

/// One param's mechanical rendering. A corpus renders a param it lacks
/// evidence on through this, so the two paths can't drift.
pub(crate) fn render_param(name: &str, value: &str, c: &SegmentClassifier) -> String {
    let mut t = c.classify(value);
    if let Some(h) = param_name_hint(name, &t) {
        t = h;
    }
    let canon = match t {
        SegmentType::Date => canonical_date(value),
        SegmentType::Currency => canonical_currency(value),
        _ => None,
    };
    match canon {
        Some(canon) => canon,
        None if matches!(t, SegmentType::Date | SegmentType::Currency) || c.variable(&t) => {
            format!("{{{}}}", display_type(&t))
        }
        None => value.to_string(),
    }
}
