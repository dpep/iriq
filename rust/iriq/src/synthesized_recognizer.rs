// Recognizer synthesized at runtime from a RecognizerProposal.
//
// Mirrors Ruby's SynthesizedRecognizer.
// Phase-2 spike scope: identify prefix-matched values and assert a type.

use crate::classifier::{Recognizer, SegmentType, Verdict};
use serde_json::{Map, Value};

// Ruby's Specificity::SEMANTIC. A proposal's prefix never fires alongside a
// built-in or another activation, so the value only has to match the rows
// Ruby writes.
const SPECIFICITY: f64 = 1.0;

pub struct SynthesizedRecognizer {
    pub prefix: String,
    pub ty: SegmentType,
    pub specificity: f64,
}

impl SynthesizedRecognizer {
    pub fn from_prefix(prefix: impl Into<String>, ty: SegmentType) -> Self {
        SynthesizedRecognizer {
            prefix: prefix.into(),
            ty,
            specificity: SPECIFICITY,
        }
    }

    pub fn from_dump(value: &Value) -> Option<Self> {
        let obj = value.as_object()?;
        let prefix = obj.get("prefix").and_then(|v| v.as_str())?;
        let ty_str = obj.get("type").and_then(|v| v.as_str())?;
        let ty = crate::classifier::segment_type_from_name(ty_str);
        let specificity = obj
            .get("specificity")
            .and_then(|v| v.as_f64())
            .unwrap_or(SPECIFICITY);
        Some(SynthesizedRecognizer {
            prefix: prefix.to_string(),
            ty,
            specificity,
        })
    }

    pub fn dump(&self) -> Value {
        let mut m = Map::new();
        m.insert("prefix".to_string(), Value::String(self.prefix.clone()));
        m.insert(
            "type".to_string(),
            Value::String(self.ty.as_str().to_string()),
        );
        m.insert(
            "specificity".to_string(),
            Value::Number(serde_json::Number::from_f64(self.specificity).unwrap()),
        );
        Value::Object(m)
    }
}

impl Recognizer for SynthesizedRecognizer {
    fn try_classify(&self, segment: &str) -> Option<Verdict> {
        // Ruby's `\A<prefix>[A-Za-z0-9]+\z`: the whole segment, ASCII suffix.
        let suffix = segment.strip_prefix(self.prefix.as_str())?;
        if suffix.is_empty() || !suffix.bytes().all(|b| b.is_ascii_alphanumeric()) {
            return None;
        }
        Some(Verdict {
            ty: self.ty.clone(),
            confidence: 1.0,
            specificity: self.specificity,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::classifier::SegmentClassifier;
    use std::sync::Arc;

    #[test]
    fn matches_the_prefix_then_ascii_alphanumerics_only() {
        let r = SynthesizedRecognizer::from_prefix(
            "ghp_",
            crate::classifier::segment_type_from_name("ghp"),
        );
        // Ruby's SynthesizedRecognizer#try on each segment.
        let cases = [
            ("ghp_abc123", true),
            ("ghp_ABC", true),
            ("ghp_abc-def", false),
            ("ghp_a.b", false),
            ("ghp_", false),
            ("ghp_x_y", false),
            ("GHP_abc", false),
            ("xghp_abc", false),
            ("ghp_é1", false),
            ("ghp_abc\n", false),
            ("ghp_١٢", false),
        ];
        for (segment, matches) in cases {
            assert_eq!(r.try_classify(segment).is_some(), matches, "{segment:?}");
        }
    }

    #[test]
    fn specificity_never_changes_a_classification() {
        let segments = [
            "ghp_abc",
            "abc_123",
            "ghp_",
            "1234",
            "2024-01-15",
            "users",
            "a_b_c",
        ];
        let classify_at = |specificity: f64| -> Vec<SegmentType> {
            let c = SegmentClassifier::new();
            for prefix in ["ghp_", "abc_"] {
                c.register_recognizer(Arc::new(SynthesizedRecognizer {
                    prefix: prefix.into(),
                    ty: crate::classifier::segment_type_from_name(prefix.trim_end_matches('_')),
                    specificity,
                }));
            }
            segments.iter().map(|s| c.classify(s)).collect()
        };
        assert_eq!(classify_at(0.3), classify_at(SPECIFICITY));
    }
}
