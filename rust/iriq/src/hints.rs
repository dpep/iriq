use crate::classifier::{SegmentClassifier, SegmentType, DEFAULT_CLASSIFIER};
use crate::inflector::singularize;
use once_cell::sync::Lazy;
use std::collections::HashSet;

#[derive(Debug, Clone)]
pub struct SegmentHint {
    pub value: String,
    pub ty: SegmentType,
    pub variable: bool,
    pub hint: String,
}

static HINT_ELIGIBLE: Lazy<HashSet<SegmentType>> = Lazy::new(|| {
    [
        SegmentType::Integer,
        SegmentType::Uuid,
        SegmentType::Hash,
        SegmentType::OpaqueId,
        SegmentType::Slug,
    ]
    .iter()
    .copied()
    .collect()
});

pub fn derive_hints(segments: &[String], c: &SegmentClassifier) -> Vec<SegmentHint> {
    let mut out = Vec::with_capacity(segments.len());
    for (i, seg) in segments.iter().enumerate() {
        let t = c.classify(seg);
        let variable = c.variable(t);
        out.push(SegmentHint {
            value: seg.clone(),
            ty: t,
            variable,
            hint: hint_for(segments, i, t, variable, c),
        });
    }
    out
}

pub fn derive_hints_default(segments: &[String]) -> Vec<SegmentHint> {
    derive_hints(segments, &DEFAULT_CLASSIFIER)
}

pub fn hint_for(
    segments: &[String],
    i: usize,
    t: SegmentType,
    variable: bool,
    c: &SegmentClassifier,
) -> String {
    if !variable || i == 0 {
        return String::new();
    }
    if !HINT_ELIGIBLE.contains(&t) {
        return String::new();
    }
    let prev = &segments[i - 1];
    if c.classify(prev) != SegmentType::Literal {
        return String::new();
    }
    let base = singularize(prev);
    let suffix = if t == SegmentType::Uuid { "_uuid" } else { "_id" };
    format!("{}{}", base, suffix)
}

pub fn hint_eligible_types() -> &'static HashSet<SegmentType> {
    &HINT_ELIGIBLE
}
