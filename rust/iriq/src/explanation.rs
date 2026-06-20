use crate::classifier::{SegmentClassifier, DEFAULT_CLASSIFIER};
use crate::errors::ParseError;
use crate::hints::{derive_hints, SegmentHint};
use crate::identifier::Identifier;
use crate::parser::parse;

pub fn explain(input: &str) -> Result<Vec<SegmentHint>, ParseError> {
    let iri = parse(input)?;
    Ok(explain_identifier(&iri, &DEFAULT_CLASSIFIER))
}

pub fn explain_identifier(iri: &Identifier, c: &SegmentClassifier) -> Vec<SegmentHint> {
    if iri.is_urn() {
        return explain_urn(iri, c);
    }
    derive_hints(&iri.path_segments, c)
}

fn explain_urn(iri: &Identifier, c: &SegmentClassifier) -> Vec<SegmentHint> {
    if iri.nss.is_empty() {
        return Vec::new();
    }
    let parts: Vec<String> = if let Some((ns, val)) = iri.nss.split_once(':') {
        vec![ns.to_string(), val.to_string()]
    } else {
        vec![iri.nss.clone()]
    };
    derive_hints(&parts, c)
}
