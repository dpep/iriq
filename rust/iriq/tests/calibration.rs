// Asserts the Rust classifier against the labeled calibration corpus, the
// same way spec/iriq/calibration_spec.rb asserts the Ruby reference. Every
// entry is checked; failures list each offending value with its category.

use serde::Deserialize;

use iriq::SegmentClassifier;

const FIXTURE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../spec/fixtures/calibration/segments.json"
);

#[derive(Deserialize)]
struct Segment {
    value: String,
    expected_type: String,
    category: String,
}

#[derive(Deserialize)]
struct CalibrationFx {
    segments: Vec<Segment>,
}

#[test]
fn calibration_segments() {
    let data =
        std::fs::read_to_string(FIXTURE).unwrap_or_else(|e| panic!("read {:?}: {}", FIXTURE, e));
    let fx: CalibrationFx =
        serde_json::from_str(&data).unwrap_or_else(|e| panic!("decode {:?}: {}", FIXTURE, e));
    assert!(!fx.segments.is_empty(), "calibration corpus has entries");

    let classifier = SegmentClassifier::new();
    let mut failures = Vec::new();
    for s in &fx.segments {
        let got = classifier.classify(&s.value);
        if got.as_str() != s.expected_type {
            failures.push(format!(
                "classify {:?} => {} (expected {}, category {})",
                s.value,
                got.as_str(),
                s.expected_type,
                s.category
            ));
        }
    }

    assert!(
        failures.is_empty(),
        "{} calibration failures:\n{}",
        failures.len(),
        failures.join("\n")
    );
}
