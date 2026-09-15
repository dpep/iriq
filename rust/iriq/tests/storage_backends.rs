//! Storage-backend behavior through the public `Corpus` surface: extension
//! routing in `open_storage`, and the SQLite round-trip including query-param
//! stats (the readback path that rebuilds PositionStats from the param tables).

use iriq::Corpus;
#[cfg(feature = "sqlite")]
use iriq::ParamSummary;
use std::path::{Path, PathBuf};

fn temp_path(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("iriq_storage_{}_{}", std::process::id(), name))
}

fn cleanup(p: &Path) {
    let base = p.to_str().unwrap();
    for side in [
        base.to_string(),
        format!("{base}-wal"),
        format!("{base}-shm"),
        format!("{base}.tmp"),
    ] {
        let _ = std::fs::remove_file(side);
    }
}

// ── extension routing ────────────────────────────────────────────────────────

#[test]
fn json_extension_routes_to_the_json_backend() {
    let p = temp_path("route.json");
    cleanup(&p);
    let path = p.to_str().unwrap();

    let mut c = Corpus::open(path).unwrap();
    c.observe("https://foo.com/users/1").unwrap();
    c.save(path).unwrap();
    c.close().unwrap();

    let data = std::fs::read(&p).unwrap();
    assert!(data.starts_with(b"{"), "expected a JSON document on disk");
    cleanup(&p);
}

#[test]
#[cfg(feature = "sqlite")]
fn sqlite_extensions_route_to_the_sqlite_backend() {
    for ext in ["db", "sqlite", "sqlite3"] {
        let p = temp_path(&format!("route_ext.{ext}"));
        cleanup(&p);
        let path = p.to_str().unwrap();

        let mut c = Corpus::open(path).unwrap();
        c.observe("https://foo.com/users/1").unwrap();
        c.close().unwrap();

        let data = std::fs::read(&p).unwrap();
        assert!(
            data.starts_with(b"SQLite format 3\0"),
            ".{ext}: expected a SQLite file on disk"
        );
        cleanup(&p);
    }
}

// ── SQLite round-trip with query params ──────────────────────────────────────

#[cfg(feature = "sqlite")]
const QUERY: &str = "https://foo.com/search";

#[cfg(feature = "sqlite")]
fn observe_param_stream(c: &mut Corpus) {
    for i in 1..=10 {
        c.observe(&format!("{QUERY}?page={i}&format=json")).unwrap();
    }
}

/// Comparable projection of the param rows (floats included — the numeric
/// range is part of what must survive persistence).
#[cfg(feature = "sqlite")]
fn param_rows(summaries: &[ParamSummary]) -> Vec<(String, String, usize, usize, f64, f64, f64)> {
    summaries
        .iter()
        .map(|p| {
            (
                p.name.clone(),
                format!("{:?}", p.ty),
                p.count,
                p.cardinality,
                p.min,
                p.max,
                p.avg,
            )
        })
        .collect()
}

#[test]
#[cfg(feature = "sqlite")]
fn sqlite_round_trips_query_param_stats() {
    let p = temp_path("params.db");
    cleanup(&p);
    let path = p.to_str().unwrap();

    let before = {
        let mut c = Corpus::open(path).unwrap();
        observe_param_stream(&mut c);
        let rows = param_rows(&c.params_for(QUERY));
        c.close().unwrap();
        rows
    };
    assert_eq!(before.len(), 2, "expected page + format rows: {before:?}");
    let page = before.iter().find(|r| r.0 == "page").unwrap();
    assert_eq!(
        (page.1.as_str(), page.2, page.4, page.5),
        ("Integer", 10, 1.0, 10.0)
    );

    let reopened = Corpus::open(path).unwrap();
    assert_eq!(param_rows(&reopened.params_for(QUERY)), before);
    cleanup(&p);
}

#[test]
#[cfg(feature = "sqlite")]
fn a_panic_inside_batch_rolls_back_and_later_writes_persist() {
    let p = temp_path("batch_panic.db");
    cleanup(&p);

    let mut c = Corpus::open(&p).unwrap();
    let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = c.batch(|c| -> iriq::Result<()> {
            c.observe("https://x.com/u/0")?;
            panic!("bug inside a batch")
        });
    }));
    assert!(panicked.is_err());

    for u in ["https://x.com/u/1", "https://x.com/u/2"] {
        c.observe(u).unwrap();
    }
    c.batch(|c| c.observe("https://x.com/u/3"))
        .expect("a later batch still works");
    drop(c);

    // u/0 was rolled back with the panicking batch; everything after persisted.
    assert_eq!(Corpus::open(&p).unwrap().observed_iri_count(), 3);
    cleanup(&p);
}

#[test]
#[cfg(feature = "sqlite")]
fn saving_to_another_spelling_of_the_live_path_flushes_in_place() {
    let dir = temp_path("alias_dir");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let live = dir.join("c.db");
    let alias = dir.join(".").join("c.db");

    let mut c = Corpus::open(&live).unwrap();
    c.observe("https://x.com/users/1").unwrap();
    c.save(&alias).unwrap();
    c.close().unwrap();
    drop(c);

    let data = std::fs::read(&live).unwrap();
    assert!(
        data.starts_with(b"SQLite format 3\0"),
        "live corpus overwritten with JSON"
    );
    assert_eq!(Corpus::open(&live).unwrap().observed_iri_count(), 1);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn exporting_to_a_sqlite_path_is_refused() {
    let target = temp_path("export.db");
    cleanup(&target);

    let mut c = Corpus::new();
    c.observe("https://x.com/users/1").unwrap();
    let err = c
        .save(&target)
        .expect_err("a JSON export under a SQLite extension");
    assert!(matches!(err, iriq::Error::Unsupported { .. }), "{err:?}");
    assert!(!target.exists(), "wrote an unopenable file");
}

// ── non-finite numbers across a reopen ───────────────────────────────────────

/// A 400-digit value overflows f64 to infinity: it counts as an observation
/// but must stay out of min/max/avg, live and after the corpus is reloaded.
fn observe_one_and_huge(c: &mut Corpus) {
    c.observe("https://inf.com/p?v=1").unwrap();
    c.observe(&format!("https://inf.com/p?v={}", "1".repeat(400)))
        .unwrap();
}

fn v_range(c: &Corpus) -> (f64, f64, f64) {
    let rows = c.params_for("https://inf.com/p?v=1");
    let v = rows
        .iter()
        .find(|p| p.name == "v")
        .expect("a `v` param row");
    (v.min, v.max, v.avg)
}

#[test]
fn a_reopened_json_corpus_keeps_infinite_values_out_of_ranges() {
    let p = temp_path("nonfinite.json");
    cleanup(&p);

    let mut c = Corpus::open(&p).unwrap();
    observe_one_and_huge(&mut c);
    c.save(&p).unwrap();
    drop(c);

    assert_eq!(v_range(&Corpus::open(&p).unwrap()), (1.0, 1.0, 1.0));
    cleanup(&p);
}

#[test]
#[cfg(feature = "sqlite")]
fn a_reopened_sqlite_corpus_keeps_infinite_values_out_of_ranges() {
    let p = temp_path("nonfinite.db");
    cleanup(&p);

    {
        let mut c = Corpus::open(&p).unwrap();
        observe_one_and_huge(&mut c);
        c.close().unwrap();
    }

    assert_eq!(v_range(&Corpus::open(&p).unwrap()), (1.0, 1.0, 1.0));
    cleanup(&p);
}

// ── JSON backend ─────────────────────────────────────────────────────────────

#[test]
fn a_json_object_without_corpus_keys_is_refused() {
    let p = temp_path("not_a_corpus.json");
    std::fs::write(&p, br#"{"name":"not a corpus"}"#).unwrap();

    let err = Corpus::open(&p).expect_err("opened a JSON file that isn't a corpus");
    assert!(matches!(err, iriq::Error::Corrupt { .. }), "{err:?}");
    assert_eq!(std::fs::read(&p).unwrap(), br#"{"name":"not a corpus"}"#);
    cleanup(&p);
}

#[test]
fn an_empty_json_object_is_an_empty_corpus() {
    let p = temp_path("empty_object.json");
    std::fs::write(&p, b"{}").unwrap();

    assert_eq!(Corpus::open(&p).unwrap().observed_iri_count(), 0);
    cleanup(&p);
}

#[test]
fn a_json_corpus_in_a_missing_directory_fails_at_open_naming_it() {
    let dir = temp_path("missing_dir");
    let _ = std::fs::remove_dir_all(&dir);
    let p = dir.join("c.json");

    let err = Corpus::open(&p).expect_err("opened a corpus with nowhere to save it");
    assert!(matches!(err, iriq::Error::Io { .. }), "{err:?}");
    assert!(err.to_string().contains(p.to_str().unwrap()), "{err}");
}

#[test]
fn concurrent_json_saves_to_one_path_all_succeed() {
    let p = temp_path("concurrent_save.json");
    cleanup(&p);

    std::thread::scope(|s| {
        for _ in 0..8 {
            s.spawn(|| {
                let mut c = Corpus::new();
                c.observe("https://x.com/users/1").unwrap();
                for _ in 0..50 {
                    c.save(&p).expect("a concurrent save failed");
                }
            });
        }
    });

    // Last writer wins; whichever it was, the file is a whole corpus.
    assert_eq!(Corpus::open(&p).unwrap().observed_iri_count(), 1);
    cleanup(&p);
}

#[test]
#[cfg(feature = "sqlite")]
fn sqlite_resave_to_same_path_is_idempotent() {
    let p = temp_path("resave.db");
    cleanup(&p);
    let path = p.to_str().unwrap();

    let mut c = Corpus::open(path).unwrap();
    observe_param_stream(&mut c);
    let before = param_rows(&c.params_for(QUERY));
    // Saving a SQLite corpus back to its own path must not rewrite it as JSON.
    c.save(path).unwrap();
    c.close().unwrap();

    let data = std::fs::read(&p).unwrap();
    assert!(data.starts_with(b"SQLite format 3\0"), "file was clobbered");

    let reopened = Corpus::open(path).unwrap();
    assert_eq!(param_rows(&reopened.params_for(QUERY)), before);
    assert_eq!(reopened.host_counts().get("foo.com"), Some(&10));
    cleanup(&p);
}
