//! A corpus reports the same numbers every time it is opened. Its numeric
//! ranges are rebuilt from the stored values on load, so an order that varies
//! per load (a hash map's) would leak into the float sum's last bits.

use iriq::Corpus;
use std::collections::BTreeSet;
use std::path::PathBuf;

fn corpus_path(ext: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("numeric-reload-{ext}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir.join(format!("c.{ext}"))
}

/// The distinct `avg`s of one numeric param across 50 opens of one corpus.
fn avgs_across_opens(path: &PathBuf) -> BTreeSet<u64> {
    let mut c = Corpus::open(path).unwrap();
    // With 1e15 in the mix, the sum's last bits depend on the order.
    for v in [
        "0.1", "0.7", "-3.25", "12", "1e15", "0.3", "2.2", "9.9", "-1.15", "4.4",
    ] {
        c.observe(&format!("https://n.com/items?v={v}")).unwrap();
    }
    c.save(path).unwrap();
    c.close().unwrap();
    drop(c);

    (0..50)
        .map(|_| {
            let rows = Corpus::open(path)
                .unwrap()
                .params_for("https://n.com/items?v=1")
                .unwrap();
            let v = rows.iter().find(|r| r.name == "v").expect("param v");
            assert!(v.numeric_count > 0, "{v:?}");
            v.avg.to_bits()
        })
        .collect()
}

#[test]
fn a_json_corpus_reports_the_same_avg_on_every_open() {
    let avgs = avgs_across_opens(&corpus_path("json"));
    assert_eq!(avgs.len(), 1, "{avgs:?}");
}

#[cfg(feature = "sqlite")]
#[test]
fn a_sqlite_corpus_reports_the_same_avg_on_every_open() {
    let avgs = avgs_across_opens(&corpus_path("db"));
    assert_eq!(avgs.len(), 1, "{avgs:?}");
}
