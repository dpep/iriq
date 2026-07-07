use crate::classifier::{
    canonical_currency, canonical_date, display_type, param_name_hint, SegmentClassifier,
    SegmentType, DEFAULT_CLASSIFIER,
};
use crate::errors::ParseError;
use crate::hints::{derive_hints, hint_eligible_types, SegmentHint};
use crate::identifier::Identifier;
use crate::inflector::singularize;
use crate::normalizer::normalize_identifier;
use crate::parser::parse;

#[derive(Debug, Clone, serde::Serialize)]
pub struct TraceRow {
    #[serde(skip_serializing_if = "String::is_empty")]
    pub name: String,
    pub value: String,
    #[serde(rename = "type")]
    pub ty: SegmentType,
    pub output: String,
    pub notes: Vec<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct TraceResult {
    pub input: String,
    pub normalized: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub scheme: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub host: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub port: Option<u64>,
    pub path: Vec<TraceRow>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub query: Vec<TraceRow>,
}

pub fn trace(input: &str) -> Result<TraceResult, ParseError> {
    let iri = parse(input)?;
    Ok(trace_identifier(&iri, &DEFAULT_CLASSIFIER, true))
}

pub fn trace_identifier(iri: &Identifier, c: &SegmentClassifier, hints: bool) -> TraceResult {
    let mut out = TraceResult {
        input: iri.canonical(),
        normalized: normalize_identifier(iri, c, hints),
        scheme: iri.scheme.clone(),
        host: iri.host.clone(),
        port: iri.port,
        path: Vec::new(),
        query: Vec::new(),
    };
    if iri.is_urn() {
        let segments = urn_parts(iri);
        out.path = trace_path(&segments, c, hints);
        return out;
    }
    out.path = trace_path(&iri.path_segments, c, hints);
    if !iri.query_params.is_empty() {
        out.query = trace_query(iri, c);
    }
    out
}

fn urn_parts(iri: &Identifier) -> Vec<String> {
    if iri.nss.is_empty() {
        return Vec::new();
    }
    if let Some((ns, val)) = iri.nss.split_once(':') {
        vec![ns.to_string(), val.to_string()]
    } else {
        vec![iri.nss.clone()]
    }
}

fn trace_path(segments: &[String], c: &SegmentClassifier, hints: bool) -> Vec<TraceRow> {
    if segments.is_empty() {
        return Vec::new();
    }
    let entries = derive_hints(segments, c);
    entries
        .iter()
        .enumerate()
        .map(|(i, e)| render_segment_row(e, segments, i, c, hints))
        .collect()
}

fn render_segment_row(
    entry: &SegmentHint,
    segments: &[String],
    idx: usize,
    c: &SegmentClassifier,
    hints: bool,
) -> TraceRow {
    let mut notes = Vec::new();
    if !entry.variable {
        return TraceRow {
            name: String::new(),
            value: entry.value.clone(),
            ty: entry.ty,
            output: entry.value.clone(),
            notes,
        };
    }

    // Canonical date / currency take precedence over placeholder rendering.
    if entry.ty == SegmentType::Date {
        if let Some(canon) = canonical_date(&entry.value) {
            if canon != entry.value {
                notes.push(format!("canonical date ({} → {})", entry.value, canon));
            }
            return TraceRow {
                name: String::new(),
                value: entry.value.clone(),
                ty: entry.ty,
                output: canon,
                notes,
            };
        }
    }
    if entry.ty == SegmentType::Currency {
        if let Some(canon) = canonical_currency(&entry.value) {
            if canon != entry.value {
                notes.push(format!("currency upcase ({} → {})", entry.value, canon));
            }
            return TraceRow {
                name: String::new(),
                value: entry.value.clone(),
                ty: entry.ty,
                output: canon,
                notes,
            };
        }
    }

    // IP umbrella collapse note
    if entry.ty == SegmentType::Ipv4 || entry.ty == SegmentType::Ipv6 {
        notes.push(format!("ip umbrella collapse ({} → ip)", entry.ty));
    }

    // Hint suppression note for semantic types.
    if hints && entry.hint.is_empty() && !hint_eligible_types().contains(&entry.ty) {
        if let Some(would) = would_be_hint(segments, idx, entry.ty, c) {
            let display = display_type(entry.ty);
            notes.push(format!(
                "semantic type — surfaced as {{{}}}, not {{{}}}",
                display, would
            ));
        }
    }

    let output = if hints && !entry.hint.is_empty() {
        format!("{{{}}}", entry.hint)
    } else {
        format!("{{{}}}", display_type(entry.ty))
    };
    TraceRow {
        name: String::new(),
        value: entry.value.clone(),
        ty: entry.ty,
        output,
        notes,
    }
}

fn would_be_hint(
    segments: &[String],
    idx: usize,
    t: SegmentType,
    c: &SegmentClassifier,
) -> Option<String> {
    if idx == 0 {
        return None;
    }
    let prev = &segments[idx - 1];
    if c.classify(prev) != SegmentType::Literal {
        return None;
    }
    let base = singularize(prev);
    let suffix = if t == SegmentType::Uuid {
        "_uuid"
    } else {
        "_id"
    };
    Some(format!("{}{}", base, suffix))
}

fn trace_query(iri: &Identifier, c: &SegmentClassifier) -> Vec<TraceRow> {
    let mut keys = iri.query_params.keys();
    keys.sort();
    let mut rows = Vec::with_capacity(keys.len());
    for k in keys {
        let v = iri.query_params.get(&k).unwrap_or("").to_string();
        rows.push(render_query_row(&k, &v, c));
    }
    rows
}

fn render_query_row(name: &str, value: &str, c: &SegmentClassifier) -> TraceRow {
    let mut notes = Vec::new();
    let base = c.classify(value);
    let effective = if let Some(h) = param_name_hint(name, base) {
        notes.push(format!(
            "param-name hint (`{}=`) lifted {} → {}",
            name, base, h
        ));
        h
    } else {
        base
    };

    let output = match effective {
        SegmentType::Date => {
            if let Some(canon) = canonical_date(value) {
                if canon != value {
                    notes.push(format!("canonical date ({} → {})", value, canon));
                }
                canon
            } else if c.variable(effective) {
                format!("{{{}}}", display_type(effective))
            } else {
                value.to_string()
            }
        }
        SegmentType::Currency => {
            if let Some(canon) = canonical_currency(value) {
                if canon != value {
                    notes.push(format!("currency upcase ({} → {})", value, canon));
                }
                canon
            } else if c.variable(effective) {
                format!("{{{}}}", display_type(effective))
            } else {
                value.to_string()
            }
        }
        SegmentType::Ipv4 | SegmentType::Ipv6 => {
            notes.push(format!("ip umbrella collapse ({} → ip)", effective));
            format!("{{{}}}", display_type(effective))
        }
        _ => {
            if c.variable(effective) {
                format!("{{{}}}", display_type(effective))
            } else {
                value.to_string()
            }
        }
    };

    TraceRow {
        name: name.to_string(),
        value: value.to_string(),
        ty: effective,
        output,
        notes,
    }
}
