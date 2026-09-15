// Ruby is the reference: its `\d`, `\s` and `\S` are ASCII-only and its
// String#size counts characters. Every expectation here is the Ruby output.

use iriq::{normalize, registrable_domain, SegmentClassifier, SegmentType};

#[test]
fn classify_matches_ruby_on_non_ascii_digits_and_spaces() {
    use SegmentType::*;
    let cases: &[(&str, SegmentType)] = &[
        (
            "1\u{966}\u{966}\u{966}\u{966}\u{966}\u{966}\u{966}",
            Literal,
        ),
        (
            "\u{662}\u{660}\u{662}\u{664}-\u{660}\u{661}-\u{660}\u{661}",
            Literal,
        ),
        ("2024\u{660}\u{661}\u{660}\u{661}", Literal),
        ("\u{661}\u{662}\u{663}", Literal),
        ("1.\u{665}", Literal),
        ("v\u{1D7CE}", Literal),
        ("+1\u{665}\u{665}\u{665}1234567", Literal),
        ("\u{665}\u{665}\u{665}-666-7777", Literal),
        ("4\u{665}.5,-122.6", Literal),
        ("2024-01-15T1\u{660}:20:30Z", Literal),
        ("12/\u{663}\u{661}/2024", Literal),
        ("\u{661}.\u{662}.\u{663}.\u{664}", Literal),
        ("1.2.3.\u{664}", Literal),
        // NBSP is not whitespace to Ruby's \S; VT is.
        ("http://x.com/a\u{A0}b", Url),
        ("foo.com/a\u{A0}b", Url),
        ("http://x.com/a\u{B}b", Literal),
        // Ruby's size guard counts chars, and /i folds U+017F (long s) to s.
        ("fal\u{17F}e", Boolean),
    ];
    let c = SegmentClassifier::new();
    for (value, want) in cases {
        assert_eq!(c.classify(value), *want, "{value:?}");
    }
}

#[test]
fn normalize_matches_ruby_on_non_ascii_digits_and_spaces() {
    let cases = [
        ("https://a.com/x?v=1.\u{665}", "https://a.com/x?v=1.\u{665}"),
        (
            "https://a.com/x?v=v\u{1D7CE}",
            "https://a.com/x?v=v\u{1D7CE}",
        ),
        (
            "https://a.com/x?u=http://x.com/a\u{A0}b",
            "https://a.com/x?u={url}",
        ),
    ];
    for (input, want) in cases {
        assert_eq!(normalize(input).unwrap(), want, "{input:?}");
    }
}

#[test]
fn non_ascii_dotted_digits_are_not_an_ipv4_literal() {
    assert_eq!(
        registrable_domain("\u{661}.\u{662}.\u{663}.\u{664}"),
        "\u{663}.\u{664}"
    );
}
