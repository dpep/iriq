// Asserts Rust normalize against the end-to-end URL calibration corpus —
// messy real-world-shaped inputs with adjudicated expected templates — the
// same way spec/iriq/url_calibration_spec.rb asserts the Ruby reference.

use serde::Deserialize;

const FIXTURE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../spec/fixtures/calibration/urls.json"
);

#[derive(Deserialize)]
struct Entry {
    input: String,
    expected_normalize: Option<String>,
    expected_error: Option<String>,
    category: String,
}

#[derive(Deserialize)]
struct UrlCalibrationFx {
    urls: Vec<Entry>,
}

#[test]
fn url_calibration() {
    let data =
        std::fs::read_to_string(FIXTURE).unwrap_or_else(|e| panic!("read {:?}: {}", FIXTURE, e));
    let fx: UrlCalibrationFx =
        serde_json::from_str(&data).unwrap_or_else(|e| panic!("decode {:?}: {}", FIXTURE, e));
    assert!(!fx.urls.is_empty(), "URL calibration corpus has entries");

    let mut failures = Vec::new();
    for e in &fx.urls {
        let got = iriq::normalize(&e.input);
        match (&e.expected_normalize, &e.expected_error) {
            (Some(want), _) => match got {
                Ok(out) if &out == want => {}
                Ok(out) => failures.push(format!(
                    "normalize {:?} => {:?} (expected {:?}, category {})",
                    e.input, out, want, e.category
                )),
                Err(err) => failures.push(format!(
                    "normalize {:?} => error {:?} (expected {:?}, category {})",
                    e.input, err, want, e.category
                )),
            },
            (None, Some(_)) => {
                if let Ok(out) = got {
                    failures.push(format!(
                        "normalize {:?} => {:?} (expected parse error, category {})",
                        e.input, out, e.category
                    ));
                }
            }
            (None, None) => failures.push(format!("entry {:?} has no expectation", e.input)),
        }
    }

    assert!(
        failures.is_empty(),
        "{} URL calibration failures:\n{}",
        failures.len(),
        failures.join("\n")
    );
}
