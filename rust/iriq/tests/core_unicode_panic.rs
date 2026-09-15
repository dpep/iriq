// Non-ASCII decimal digits (Unicode Nd) used to match the classifier's date
// and integer patterns, which then byte-sliced mid-character and panicked.
// Ruby's `\d` is ASCII-only, so these are plain literals there.

use iriq::{canonical_date, normalize};

const DEVANAGARI_ZEROS: &str = "1\u{966}\u{966}\u{966}\u{966}\u{966}\u{966}\u{966}";
const ARABIC_INDIC_DATE: &str = "\u{662}\u{660}\u{662}\u{664}-\u{660}\u{661}-\u{660}\u{661}";

#[test]
fn normalize_leaves_non_ascii_digit_values_as_literals() {
    let cases = [
        format!("https://x.com/{DEVANAGARI_ZEROS}"),
        format!("https://x.com/a?d={DEVANAGARI_ZEROS}"),
        "https://a.com/x?d=2024-\u{660}\u{661}-\u{661}\u{665}".to_string(),
        "https://a.com/x?d=2024/\u{660}\u{661}/\u{661}\u{665}".to_string(),
    ];
    for url in cases {
        assert_eq!(normalize(&url).unwrap(), url, "{url:?}");
    }
}

#[test]
fn canonical_date_rejects_non_ascii_digits() {
    for v in [
        ARABIC_INDIC_DATE,
        "2024-\u{660}\u{661}-\u{661}\u{665}",
        "2024/\u{660}\u{661}/\u{661}\u{665}",
        "12/\u{663}\u{661}/2024",
        "2024\u{660}\u{661}\u{660}\u{661}",
    ] {
        assert_eq!(canonical_date(v), None, "{v:?}");
    }
}
