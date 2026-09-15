//! Corpus-informed normalization: a path slot that holds many distinct
//! *literal* values (mechanically un-promotable) should collapse to a
//! placeholder once the corpus has seen enough of them. Regression guard for
//! the literal-promotion path.

use iriq::Corpus;

const NAMES: [&str; 26] = [
    "alice", "bob", "carol", "dave", "eve", "frank", "grace", "heidi", "ivan", "judy", "ken",
    "leo", "mary", "ned", "olive", "peg", "quinn", "rose", "sam", "tom", "uma", "vic", "wade",
    "xena", "yara", "zoe",
];

#[test]
fn promotes_high_cardinality_literal_midpath() {
    // The variable slot is mid-path, with a `profile` suffix after it.
    let mut c = Corpus::new();
    for n in NAMES {
        c.observe(&format!("https://foo.com/users/{n}/profile"))
            .unwrap();
    }
    assert_eq!(
        c.normalize("https://foo.com/users/zoe/profile").unwrap(),
        "https://foo.com/users/{user}/profile"
    );
}

#[test]
fn promotes_high_cardinality_literal_endpath() {
    // Same, with the variable slot at the end of the path (no suffix).
    let mut c = Corpus::new();
    for n in NAMES {
        c.observe(&format!("https://foo.com/users/{n}")).unwrap();
    }
    assert_eq!(
        c.normalize("https://foo.com/users/zoe").unwrap(),
        "https://foo.com/users/{user}"
    );
}

#[test]
fn promotion_survives_save_and_reopen() {
    let path =
        std::env::temp_dir().join(format!("iriq_promo_roundtrip_{}.json", std::process::id()));
    let p = path.to_str().unwrap();
    let _ = std::fs::remove_file(&path);
    {
        let mut c = Corpus::open(p).unwrap();
        for n in NAMES {
            c.observe(&format!("https://foo.com/users/{n}/profile"))
                .unwrap();
        }
        c.save(p).unwrap();
    }
    let c = Corpus::open(p).unwrap();
    assert_eq!(
        c.normalize("https://foo.com/users/zoe/profile").unwrap(),
        "https://foo.com/users/{user}/profile"
    );
    let _ = std::fs::remove_file(&path);
}

#[test]
fn ip_addresses_render_as_ip_like_mechanical_normalize() {
    // Mechanical normalize (and Ruby) collapse IPv4 and IPv6 into one `{ip}`
    // placeholder; the corpus path must not leak the subtype.
    let c = Corpus::new();
    assert_eq!(
        c.normalize("https://a.com/hosts/10.0.0.1").unwrap(),
        "https://a.com/hosts/{ip}"
    );
    let query = c.normalize("https://a.com/lookup?addr=10.0.0.1").unwrap();
    assert!(
        query.contains("{ip}") && !query.contains("{ipv4}"),
        "{query}"
    );
}

#[test]
fn low_cardinality_literal_stays_literal() {
    // A slot that always holds the same literal must NOT be promoted, however
    // many times it's seen.
    let mut c = Corpus::new();
    for _ in 0..NAMES.len() {
        c.observe("https://foo.com/about/team").unwrap();
    }
    assert_eq!(
        c.normalize("https://foo.com/about/team").unwrap(),
        "https://foo.com/about/team"
    );
}
