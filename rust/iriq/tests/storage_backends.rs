//! Storage-backend behavior through the public `Corpus` surface: extension
//! routing in `open_storage`, and the SQLite round-trip including query-param
//! stats (the readback path that rebuilds PositionStats from the param tables).

use iriq::{Corpus, ParamSummary};
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

const QUERY: &str = "https://foo.com/search";

fn observe_param_stream(c: &mut Corpus) {
    for i in 1..=10 {
        c.observe(&format!("{QUERY}?page={i}&format=json")).unwrap();
    }
}

/// Comparable projection of the param rows (floats included — the numeric
/// range is part of what must survive persistence).
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
