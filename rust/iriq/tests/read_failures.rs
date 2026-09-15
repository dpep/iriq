//! A corpus read that fails is an error, never "no evidence": a swallowed read
//! prints a plausible shape or count and exits 0, which is indistinguishable
//! from a real answer.
#![cfg(feature = "sqlite")]

mod common;

use iriq::Corpus;
use rusqlite::Connection;
use std::path::{Path, PathBuf};

/// A SQLite corpus with a few observations under `foo.com`.
fn corpus(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("read-failures-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("c.db");
    let mut c = Corpus::open(&path).unwrap();
    for i in 1..=6 {
        c.observe(&format!("https://foo.com/users/{i}?page={i}"))
            .unwrap();
    }
    c.close().unwrap();
    path
}

/// A row no read can decode: an INTEGER column holding text. Writes never
/// touch it, so only a read can notice.
fn corrupt(path: &Path, sql: &str) {
    Connection::open(path).unwrap().execute_batch(sql).unwrap();
}

const BAD_TYPE_ROW: &str = "INSERT INTO position_types (host, scope, locator, type, count) \
                            VALUES ('foo.com', 'path', '', 'slug', 'not a count')";

#[test]
fn a_failed_read_fails_corpus_normalize() {
    let path = corpus("lib");
    let c = Corpus::open(&path).unwrap();
    corrupt(&path, BAD_TYPE_ROW);
    let err = c
        .normalize("https://foo.com/users/7")
        .expect_err("normalized from a corpus it couldn't read");
    assert!(err.to_string().contains(path.to_str().unwrap()), "{err}");
}

#[test]
fn a_failed_read_fails_the_corpus_reports() {
    let path = corpus("reports");
    corrupt(
        &path,
        "INSERT INTO host_counts (host, count) VALUES ('ghost.com', 'not a count');\
         INSERT INTO cluster_param_types (cluster_key, name, type, count) \
         SELECT key, 'page', 'slug', 'not a count' FROM clusters",
    );
    let c = Corpus::open(&path).unwrap();
    assert!(c.host_counts().is_err(), "host_counts");
    assert!(c.clusters().is_err(), "clusters");
    assert!(c.cross_host_shapes(1).is_err(), "cross_host_shapes");
    assert!(
        c.params_for("https://foo.com/users/7").is_err(),
        "params_for"
    );
}

#[test]
fn unparseable_input_is_an_error_everywhere_a_corpus_takes_input() {
    let c = Corpus::new();
    let bad = "not a url at all \u{0}";
    assert!(c.normalize(bad).is_err());
    assert!(c.explain(bad).is_err());
    assert!(c.params_for(bad).is_err());
}

fn assert_corpus_error(out: &std::process::Output, path: &Path) {
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(
        out.status.code(),
        Some(1),
        "stdout: {}",
        String::from_utf8_lossy(&out.stdout)
    );
    assert!(
        stderr.starts_with(&format!("iriq: corpus {}: ", path.display())),
        "{stderr}"
    );
}

#[test]
fn cli_stats_exits_1_when_a_read_fails() {
    let path = corpus("cli-stats");
    corrupt(
        &path,
        "INSERT INTO host_counts (host, count) VALUES ('ghost.com', 'not a count')",
    );
    let out = common::iriq()
        .args(["--stats", "--corpus"])
        .arg(&path)
        .output()
        .unwrap();
    assert_corpus_error(&out, &path);

    let out = common::iriq()
        .args(["--stats", "--json", "--corpus"])
        .arg(&path)
        .output()
        .unwrap();
    let err: serde_json::Value = serde_json::from_slice(&out.stderr).expect("json error");
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(err["error"]["code"], "corpus_error", "{err}");
}

#[test]
fn cli_normalize_exits_1_when_an_evidence_read_fails() {
    let path = corpus("cli-normalize");
    corrupt(&path, BAD_TYPE_ROW);
    let out = common::iriq()
        .args(["-n", "--corpus"])
        .arg(&path)
        .arg("https://foo.com/users/7")
        .output()
        .unwrap();
    assert_corpus_error(&out, &path);
}
