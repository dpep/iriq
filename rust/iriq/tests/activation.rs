//! Proposal activation registers a dynamic Custom type (e.g. `ghp`) —
//! Ruby models types as symbols, so an activated recognizer classifies
//! under its suggested name, not a fallback. The activation must also
//! survive a corpus reopen from disk. Mirrors Ruby's
//! activate_proposal_spec.

use iriq::classifier::{segment_type_from_name, SegmentType};
use iriq::recognizer_proposal::ProposalOptions;
use iriq::Corpus;

fn observe_pat_stream(c: &mut Corpus) {
    for i in 0..25 {
        c.observe(&format!("https://api.github.com/auth/ghp_aaaa{i:04}xyzzy"))
            .unwrap();
    }
}

#[test]
fn activates_under_the_suggested_custom_type() {
    let mut c = Corpus::new();
    observe_pat_stream(&mut c);

    let activated = c
        .activate_proposals_above(0.9, ProposalOptions::default())
        .unwrap();
    assert_eq!(activated.len(), 1);
    assert_eq!(activated[0].ty.as_str(), "ghp");
    assert_eq!(
        c.normalize("https://api.github.com/auth/ghp_zzzz9999xyzzy")
            .unwrap(),
        "https://api.github.com/auth/{ghp}"
    );
}

#[test]
fn custom_type_survives_sqlite_reopen() {
    let dir = std::env::temp_dir().join(format!("iriq-activation-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("act.db");
    let path_str = path.to_str().unwrap();

    {
        let mut c = Corpus::open(path_str).unwrap();
        observe_pat_stream(&mut c);
        let activated = c
            .activate_proposals_above(0.9, ProposalOptions::default())
            .unwrap();
        assert_eq!(activated.len(), 1);
    }

    let reopened = Corpus::open(path_str).unwrap();
    assert_eq!(
        reopened
            .normalize("https://api.github.com/auth/ghp_zzzz9999xyzzy")
            .unwrap(),
        "https://api.github.com/auth/{ghp}"
    );

    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn interning_returns_the_same_custom_instance() {
    let a = segment_type_from_name("ghp");
    let b = segment_type_from_name("ghp");
    assert_eq!(a, b);
    assert_eq!(a.as_str(), "ghp");
    // Known names still resolve to their proper variants.
    assert_eq!(segment_type_from_name("integer"), SegmentType::Integer);
}
