// Property-based never-crash suite, mirroring spec/iriq/property_spec.rb.
//
// Fixture tests pin exact outputs for curated inputs; this file sweeps
// arbitrary and hostile strings and asserts the invariants that must hold
// on ANY input: parse/extract/normalize/explain never panic, canonical is
// idempotent for parseable inputs, and everything is deterministic.

use iriq::{explain, normalize, parse, Corpus, Extractor};
use proptest::prelude::*;

/// Ruby String#strip semantics (ASCII whitespace + NUL), mirroring the
/// parser's input stripping. Used to narrow the idempotence invariant the
/// same way the Ruby property spec does.
fn ruby_strip(s: &str) -> &str {
    s.trim_matches([' ', '\t', '\r', '\n', '\x0B', '\x0C', '\0'])
}

// The same messy-injection pool the Ruby property spec uses: spaces, braces,
// pipes, NULs-as-escapes, bad percent-escapes, Unicode whitespace/quotes,
// and URL metacharacters.
const INJECTIONS: &[&str] = &[
    " ", "{", "}", "|", "%00", "%zz", "%", "%%", "\\", "^", "<", ">", "\u{00A0}", "\u{3000}",
    "\u{201C}", "\u{201D}", "é", "例", "🦀", "\t", "..", "//", "?", "#", ":", "@",
];

fn clean_url() -> impl Strategy<Value = String> {
    (
        prop_oneof![
            Just("https"),
            Just("http"),
            Just("ftp"),
            Just("urn"),
            Just("")
        ],
        "[a-zA-Z0-9-]{1,10}\\.[a-zA-Z]{2,4}",
        proptest::collection::vec("[a-zA-Z0-9._~%-]{1,10}", 0..4),
        proptest::option::of("[a-zA-Z0-9=&%+-]{1,20}"),
        proptest::option::of("[a-zA-Z0-9]{1,8}"),
    )
        .prop_map(|(scheme, host, segments, query, fragment)| {
            let mut s = match scheme {
                "" => host,
                "urn" => format!("urn:{}", host),
                _ => format!("{}://{}", scheme, host),
            };
            for seg in &segments {
                s.push('/');
                s.push_str(seg);
            }
            if let Some(q) = query {
                s.push('?');
                s.push_str(&q);
            }
            if let Some(f) = fragment {
                s.push('#');
                s.push_str(&f);
            }
            s
        })
}

/// One random corruption, mirroring the Ruby mutator: truncation, injection,
/// percent-doubling, char swaps, prepended/appended garbage.
fn mutate(s: String, kind: usize, idx: prop::sample::Index, inj: &str) -> String {
    match kind {
        0 => {
            // truncate (at a char boundary — &str can't split a code point)
            let chars: Vec<char> = s.chars().collect();
            if chars.len() > 1 {
                let n = 1 + idx.index(chars.len() - 1);
                chars[..n].iter().collect()
            } else {
                s
            }
        }
        1 => {
            // inject at a random position
            let mut s = s;
            let boundaries: Vec<usize> = (0..=s.len()).filter(|&i| s.is_char_boundary(i)).collect();
            let p = boundaries[idx.index(boundaries.len())];
            s.insert_str(p, inj);
            s
        }
        2 => s.replace('%', "%25"), // double percent-encoding
        3 => {
            // swap two chars
            let mut chars: Vec<char> = s.chars().collect();
            if chars.len() >= 2 {
                let a = idx.index(chars.len());
                let b = (a + 1 + idx.index(chars.len() - 1)) % chars.len();
                chars.swap(a, b);
                chars.into_iter().collect()
            } else {
                s
            }
        }
        4 => format!("{}{}", inj, s),
        _ => format!("{}{}", s, inj),
    }
}

fn messy_url() -> impl Strategy<Value = String> {
    (
        clean_url(),
        proptest::collection::vec(
            (
                0usize..6,
                any::<prop::sample::Index>(),
                prop::sample::select(INJECTIONS),
            ),
            0..3,
        ),
    )
        .prop_map(|(url, mutations)| {
            mutations
                .into_iter()
                .fold(url, |s, (kind, idx, inj)| mutate(s, kind, idx, inj))
        })
}

/// Everything the invariants must hold for on a single input.
fn check_invariants(input: &str) {
    // parse: Ok or Err — a panic fails the test. Deterministic.
    let first = parse(input);
    let second = parse(input);
    assert_eq!(
        first.is_ok(),
        second.is_ok(),
        "parse not deterministic for {:?}",
        input
    );

    // extract never panics on arbitrary text.
    let _ = Extractor::new().extract(input);
    let _ = Extractor::new().extract(&format!("see {} and {} ok", input, input));

    // normalize/explain succeed exactly when parse does, and never panic.
    let norm = normalize(input);
    assert_eq!(
        first.is_ok(),
        norm.is_ok(),
        "normalize disagrees with parse for {:?}",
        input
    );
    let _ = explain(input);

    if let Ok(iri) = first {
        assert_eq!(
            iri.canonical(),
            second.unwrap().canonical(),
            "canonical not deterministic for {:?}",
            input
        );
        assert_eq!(
            norm.unwrap(),
            normalize(input).unwrap(),
            "normalize not deterministic for {:?}",
            input
        );

        // Canonical idempotence. KNOWN-GAP (mirrors the Ruby property
        // spec): parse strips leading/trailing whitespace, so a canonical
        // that itself ends in whitespace re-strips on the second pass.
        let canonical = iri.canonical();
        if ruby_strip(&canonical) == canonical {
            let reparsed = parse(&canonical).unwrap_or_else(|e| {
                panic!(
                    "canonical {:?} of {:?} failed to reparse: {}",
                    canonical, input, e
                )
            });
            assert_eq!(
                reparsed.canonical(),
                canonical,
                "canonical not idempotent for {:?}",
                input
            );
        }
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 512, ..ProptestConfig::default() })]

    #[test]
    fn arbitrary_strings_never_panic(input in any::<String>()) {
        check_invariants(&input);
    }

    #[test]
    fn messy_urls_never_panic(input in messy_url()) {
        check_invariants(&input);
    }

    #[test]
    fn corpus_observe_and_normalize_never_panic(inputs in proptest::collection::vec(messy_url(), 1..12)) {
        let mut corpus = Corpus::new();
        for input in &inputs {
            let _ = corpus.observe(input); // Err is fine; panic is not
        }
        for input in &inputs {
            let _ = corpus.normalize(input);
        }
    }
}

// ── Pinned regressions for divergences the property sweep surfaced ─────────
// (Rust previously disagreed with the Ruby reference on all of these.)

#[test]
fn port_zero_is_preserved() {
    let iri = parse("https://foo.com:0/x").unwrap();
    assert_eq!(iri.port, Some(0));
    assert_eq!(iri.canonical(), "https://foo.com:0/x");
}

#[test]
fn out_of_range_port_is_accepted_verbatim() {
    // Ruby's port.to_i has no u16 ceiling; the lenient parser keeps it.
    let iri = parse("https://foo.com:99999/x").unwrap();
    assert_eq!(iri.port, Some(99999));
}

#[test]
fn unicode_digits_are_not_a_port() {
    // Ruby's \d is ASCII-only: "٣٣" falls into the host, not the port.
    let iri = parse("https://foo.com:٣٣/x").unwrap();
    assert_eq!(iri.host, "foo.com:٣٣");
    assert_eq!(iri.port, None);
}

#[test]
fn host_downcases_with_full_unicode_case_mapping() {
    assert_eq!(parse("https://EXÄMPLE.com/x").unwrap().host, "exämple.com");
}

#[test]
fn unicode_whitespace_is_not_stripped_from_input() {
    // Ruby String#strip is ASCII-only, so a leading U+3000 blocks the parse.
    assert!(parse("\u{3000}https://foo.com/x").is_err());
}

#[test]
fn bare_opaque_scheme_is_rejected() {
    assert!(parse("mailto:").is_err());
    assert!(parse("mailto:foo@bar").is_ok());
}

#[test]
fn extract_allows_non_ascii_word_chars_at_left_boundary() {
    // Ruby's \w is ASCII-only: "é" before a URL does not block extraction.
    let urls = Extractor::new().extract_strings("é https://foo.com/a and éhttps://foo.com/b");
    assert_eq!(urls, vec!["https://foo.com/a", "https://foo.com/b"]);
}

#[test]
fn extract_rescans_inside_a_boundary_blocked_candidate() {
    // Ruby's left-boundary guard is a lookbehind: blocking a candidate only
    // bumps the scan position by one char, so a candidate nested inside the
    // blocked match is still found.
    let urls = Extractor::new().extract_strings("//https://app.exa%zzmple.com/workspaces/poplar");
    assert_eq!(urls, vec!["https://zzmple.com/workspaces/poplar"]);
}

#[test]
fn extract_keeps_unicode_whitespace_inside_url() {
    // Ruby's \s is ASCII-only: U+00A0 is a legal URL char, not a boundary.
    let urls = Extractor::new().extract_strings("see https://foo.com/a\u{00A0}b end");
    assert_eq!(urls, vec!["https://foo.com/a\u{00A0}b"]);
}
