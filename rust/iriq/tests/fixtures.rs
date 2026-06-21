// Loads the golden JSON fixtures under spec/fixtures/ and asserts that the
// Rust implementation produces the same outputs that the Ruby and Go
// implementations produce.

use serde::Deserialize;
use std::collections::HashMap;
use std::path::PathBuf;

use iriq::{
    normalize_identifier, parse, path_shape_for, singularize, Extractor, SegmentClassifier,
};

fn fixtures_dir() -> PathBuf {
    // The Rust crate sits at rust/iriq; spec/fixtures lives at the repo root.
    let here = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    here.join("../..").join("spec").join("fixtures")
}

fn load<T: for<'de> Deserialize<'de>>(name: &str) -> T {
    let path = fixtures_dir().join(name);
    let data = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {:?}: {}", path, e));
    serde_json::from_str(&data).unwrap_or_else(|e| panic!("decode {:?}: {}", path, e))
}

// ─── Parser ──────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct ParserCase {
    input: String,
    identifier: ParserIdent,
}

#[derive(Deserialize)]
struct ParserIdent {
    original: String,
    kind: String,
    scheme: Option<String>,
    host: Option<String>,
    port: Option<u16>,
    path_segments: Vec<String>,
    query_params: HashMap<String, String>,
    fragment: Option<String>,
    nss: Option<String>,
    canonical: String,
}

#[derive(Deserialize)]
struct ParserFx {
    cases: Vec<ParserCase>,
}

#[test]
fn fixture_parser() {
    let fx: ParserFx = load("parser.json");
    for c in &fx.cases {
        let iri = parse(&c.input).unwrap_or_else(|e| panic!("parse {:?}: {}", c.input, e));
        assert_eq!(
            iri.original, c.identifier.original,
            "{:?} original",
            c.input
        );
        assert_eq!(iri.kind.as_str(), c.identifier.kind, "{:?} kind", c.input);
        assert_eq!(
            opt(iri.scheme.as_str()),
            c.identifier.scheme,
            "{:?} scheme",
            c.input
        );
        assert_eq!(
            opt(iri.host.as_str()),
            c.identifier.host,
            "{:?} host",
            c.input
        );
        let want_port = c.identifier.port;
        let got_port = if iri.port == 0 { None } else { Some(iri.port) };
        assert_eq!(got_port, want_port, "{:?} port", c.input);
        assert_eq!(
            iri.path_segments, c.identifier.path_segments,
            "{:?} segments",
            c.input
        );
        let got_qp: HashMap<String, String> = iri
            .query_params
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        assert_eq!(got_qp, c.identifier.query_params, "{:?} query", c.input);
        assert_eq!(
            opt(iri.fragment.as_str()),
            c.identifier.fragment,
            "{:?} frag",
            c.input
        );
        assert_eq!(opt(iri.nss.as_str()), c.identifier.nss, "{:?} nss", c.input);
        assert_eq!(
            iri.canonical(),
            c.identifier.canonical,
            "{:?} canonical",
            c.input
        );
    }
}

fn opt(s: &str) -> Option<String> {
    if s.is_empty() {
        None
    } else {
        Some(s.to_string())
    }
}

// ─── Classifier ──────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct ClassifierCase {
    input: String,
    #[serde(rename = "type")]
    ty: String,
}

#[derive(Deserialize)]
struct ClassifierFx {
    cases: Vec<ClassifierCase>,
}

#[test]
fn fixture_classifier() {
    let fx: ClassifierFx = load("classifier.json");
    let c = SegmentClassifier::new();
    for case in &fx.cases {
        let got = c.classify(&case.input);
        assert_eq!(got.as_str(), case.ty, "classify {:?}", case.input);
    }
}

// ─── Normalizer ──────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct NormalizerCase {
    input: String,
    hints: bool,
    output: String,
}

#[derive(Deserialize)]
struct NormalizerFx {
    cases: Vec<NormalizerCase>,
}

#[test]
fn fixture_normalizer() {
    let fx: NormalizerFx = load("normalizer.json");
    let c = SegmentClassifier::new();
    for case in &fx.cases {
        let iri = parse(&case.input).unwrap();
        let got = normalize_identifier(&iri, &c, case.hints);
        assert_eq!(
            got, case.output,
            "normalize {:?} hints={}",
            case.input, case.hints
        );
    }
}

// ─── PathShape ───────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct PathShapeCase {
    segments: Vec<String>,
    hints: bool,
    shape: String,
}

#[derive(Deserialize)]
struct PathShapeFx {
    cases: Vec<PathShapeCase>,
}

#[test]
fn fixture_path_shape() {
    let fx: PathShapeFx = load("pathshape.json");
    for case in &fx.cases {
        let got = path_shape_for(&case.segments, case.hints);
        assert_eq!(
            got, case.shape,
            "pathshape {:?} hints={}",
            case.segments, case.hints
        );
    }
}

// ─── Inflector ───────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct InflectorCase {
    input: String,
    singular: String,
}

#[derive(Deserialize)]
struct InflectorFx {
    cases: Vec<InflectorCase>,
}

#[test]
fn fixture_inflector() {
    let fx: InflectorFx = load("inflector.json");
    for case in &fx.cases {
        let got = singularize(&case.input);
        assert_eq!(got, case.singular, "singularize {:?}", case.input);
    }
}

// ─── Extractor ───────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct ExtractorCase {
    text: String,
    extracted: Vec<String>,
    strict: Vec<String>,
}

#[derive(Deserialize)]
struct ExtractorFx {
    cases: Vec<ExtractorCase>,
}

#[test]
fn fixture_extractor() {
    let fx: ExtractorFx = load("extractor.json");
    let scheme_less = Extractor { scheme_less: true };
    let strict = Extractor { scheme_less: false };
    for case in &fx.cases {
        let got_sl = scheme_less.extract_strings(&case.text);
        assert_eq!(
            got_sl, case.extracted,
            "extract scheme-less {:?}",
            case.text
        );
        let got_strict = strict.extract_strings(&case.text);
        assert_eq!(got_strict, case.strict, "extract strict {:?}", case.text);
    }
}
