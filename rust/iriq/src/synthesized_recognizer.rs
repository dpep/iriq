// Recognizer synthesized at runtime from a RecognizerProposal.
//
// Mirrors Go's SynthesizedRecognizer / Ruby's SynthesizedRecognizer.
// Phase-2 spike scope: identify prefix-matched values and assert a type.

use crate::classifier::{Recognizer, SegmentType, Verdict};
use serde_json::{Map, Value};

const SPECIFICITY_PATTERN: f64 = 0.3;

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
            specificity: SPECIFICITY_PATTERN,
        }
    }

    pub fn from_dump(value: &Value) -> Option<Self> {
        let obj = value.as_object()?;
        let prefix = obj.get("prefix").and_then(|v| v.as_str())?;
        let ty_str = obj.get("type").and_then(|v| v.as_str())?;
        let ty = crate::classifier::segment_type_from_str(ty_str)?;
        let specificity = obj
            .get("specificity")
            .and_then(|v| v.as_f64())
            .unwrap_or(SPECIFICITY_PATTERN);
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
        if !segment.starts_with(&self.prefix) {
            return None;
        }
        Some(Verdict {
            ty: self.ty,
            confidence: 1.0,
            specificity: self.specificity,
        })
    }
}
