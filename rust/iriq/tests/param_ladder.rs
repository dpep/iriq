//! The query-param confidence ladder: constant → string → enum, plus the
//! confidence score and straggler-robust enum detection. Mirrors the Ruby
//! corpus_spec ladder examples.

use iriq::{Corpus, SegmentType};

#[test]
fn constant_param_renders_its_value() {
    let mut c = Corpus::new();
    for _ in 0..10 {
        c.observe("https://foo.com/x?format=json").unwrap();
    }
    assert_eq!(
        c.params_for("https://foo.com/x")[0].ty,
        SegmentType::Literal
    );
    assert_eq!(
        c.normalize("https://foo.com/x?format=json").unwrap(),
        "https://foo.com/x?format=json"
    );
}

#[test]
fn lone_value_stays_constant_past_enum_threshold() {
    let mut c = Corpus::new();
    for _ in 0..40 {
        c.observe("https://foo.com/c?format=json").unwrap();
    }
    // A single repeated value is a constant, not a one-member enum.
    assert_eq!(
        c.params_for("https://foo.com/c")[0].ty,
        SegmentType::Literal
    );
}

#[test]
fn varying_literal_is_string() {
    let mut c = Corpus::new();
    for v in ["asc", "desc", "name", "created", "updated"] {
        c.observe(&format!("https://foo.com/y?sort={v}")).unwrap();
    }
    assert_eq!(c.params_for("https://foo.com/y")[0].ty, SegmentType::String);
    assert_eq!(
        c.normalize("https://foo.com/y?sort=relevance").unwrap(),
        "https://foo.com/y?sort={string}"
    );
}

#[test]
fn bounded_set_graduates_to_enum() {
    let mut c = Corpus::new();
    for _ in 0..20 {
        c.observe("https://foo.com/z?state=on").unwrap();
        c.observe("https://foo.com/z?state=off").unwrap();
    }
    assert_eq!(c.params_for("https://foo.com/z")[0].ty, SegmentType::Enum);
}

#[test]
fn enum_survives_a_straggler() {
    let mut c = Corpus::new();
    for _ in 0..30 {
        c.observe("https://foo.com/posts?status=published").unwrap();
    }
    for _ in 0..20 {
        c.observe("https://foo.com/posts?status=draft").unwrap();
    }
    c.observe("https://foo.com/posts?status=typo").unwrap(); // straggler
    let p = &c.params_for("https://foo.com/posts")[0];
    assert_eq!(p.ty, SegmentType::Enum);
    assert_eq!(p.values.len(), 2, "only established members are advertised");
}

#[test]
fn confidence_rises_and_is_bounded() {
    let mut c = Corpus::new();
    c.observe("https://foo.com/x?a=1").unwrap();
    let low = c.params_for("https://foo.com/x")[0].confidence;
    for _ in 0..1000 {
        c.observe("https://foo.com/x?a=1").unwrap();
    }
    let high = c.params_for("https://foo.com/x")[0].confidence;
    assert!(low > 0.0 && low < high && high <= 1.0);
    assert!(high > 0.9, "abundant evidence → near-certain, got {high}");
}
