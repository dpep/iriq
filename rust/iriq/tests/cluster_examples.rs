//! A SQLite-backed cluster dedupes its examples by canonical, matching the
//! in-memory `Cluster::add` path. Regression guard against the SQLite example
//! insert drifting from the Memory backend (it once stored duplicates).

use iriq::Corpus;

#[test]
fn sqlite_dedupes_cluster_examples() {
    let path = std::env::temp_dir().join(format!("iriq_cluster_dedup_{}.db", std::process::id()));
    let p = path.to_str().unwrap();
    let _ = std::fs::remove_file(&path);

    let mut c = Corpus::open(p).unwrap();
    for _ in 0..3 {
        c.observe("https://foo.com/users/1").unwrap();
    }
    c.observe("https://foo.com/users/2").unwrap();

    let cluster = &c.clusters()[0];
    assert_eq!(cluster.count, 4);
    let examples: Vec<String> = cluster.examples.iter().map(|e| e.canonical()).collect();
    assert_eq!(
        examples,
        vec![
            "https://foo.com/users/1".to_string(),
            "https://foo.com/users/2".to_string(),
        ]
    );

    let _ = std::fs::remove_file(&path);
}
