//! A position keeps at most `max_values_per_position` distinct values. A
//! writer that remembers how many a position holds (instead of counting per
//! new value) must still honor the cap when other processes write the same
//! `.db`, and must notice when another process clears the views.
#![cfg(feature = "sqlite")]

use iriq::Corpus;
use rusqlite::{params, Connection};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

const CAP: usize = 20;
const WRITERS: usize = 4;
const OBSERVATIONS_PER_WRITER: usize = 150;

/// A fresh corpus whose stored value cap is `cap`.
fn corpus_with_cap(name: &str, cap: usize) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("perf-value-counts-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("c.db");
    Corpus::open(&path).unwrap().close().unwrap();
    Connection::open(&path)
        .unwrap()
        .execute(
            "UPDATE meta SET value = ? WHERE key = 'max_values_per_position'",
            params![cap.to_string()],
        )
        .unwrap();
    path
}

/// (distinct values tracked, observations) at `x.com`'s `/t/<value>` slot.
fn slot(path: &Path) -> (usize, usize) {
    let conn = Connection::open(path).unwrap();
    let tracked: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM position_values WHERE host = 'x.com' AND locator = '/t'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    let total: i64 = conn
        .query_row(
            "SELECT total FROM position_stats WHERE host = 'x.com' AND locator = '/t'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    (tracked as usize, total as usize)
}

#[test]
fn a_clear_by_another_connection_reopens_the_capped_slot() {
    let path = corpus_with_cap("clear", 3);
    let mut corpus = Corpus::open(&path).unwrap();
    corpus
        .batch(|c| {
            for v in ["a", "b", "c", "d"] {
                c.observe(&format!("https://x.com/t/{v}"))?;
            }
            Ok(())
        })
        .unwrap();
    assert_eq!(slot(&path), (3, 4));

    // What another process's reinfer does before it replays.
    Connection::open(&path)
        .unwrap()
        .execute("DELETE FROM position_values", [])
        .unwrap();

    corpus.batch(|c| c.observe("https://x.com/t/e")).unwrap();
    assert_eq!(slot(&path).0, 1, "the cleared slot took no new value");
}

/// Runs only as a child of the test below.
#[test]
fn value_cap_writer_process() {
    let (Ok(path), Ok(id)) = (
        std::env::var("IRIQ_PERF_WRITER_DB"),
        std::env::var("IRIQ_PERF_WRITER_ID"),
    ) else {
        return;
    };
    let mut corpus = Corpus::open(&path).unwrap();
    // Every writer takes its first count of the slot before any can fill it;
    // otherwise one writer fills the cap and the rest never insert at all.
    corpus
        .batch(|c| c.observe(&format!("https://x.com/t/w{id}first")))
        .unwrap();
    std::fs::write(format!("{path}.ready.{id}"), b"").unwrap();
    let go = PathBuf::from(format!("{path}.go"));
    while !go.exists() {
        std::thread::sleep(Duration::from_millis(1));
    }
    for i in 1..OBSERVATIONS_PER_WRITER {
        // One transaction per observation, then a pause so writers interleave.
        corpus
            .batch(|c| c.observe(&format!("https://x.com/t/w{id}v{i}")))
            .unwrap();
        std::thread::sleep(Duration::from_micros(500));
    }
}

#[test]
fn concurrent_writer_processes_never_exceed_the_value_cap() {
    let path = corpus_with_cap("processes", CAP);
    let children: Vec<_> = (0..WRITERS)
        .map(|id| {
            Command::new(std::env::current_exe().unwrap())
                .args(["value_cap_writer_process", "--exact", "--nocapture"])
                .env("IRIQ_PERF_WRITER_DB", &path)
                .env("IRIQ_PERF_WRITER_ID", id.to_string())
                .spawn()
                .unwrap()
        })
        .collect();
    let all_ready =
        || (0..WRITERS).all(|id| Path::new(&format!("{}.ready.{id}", path.display())).exists());
    while !all_ready() {
        std::thread::sleep(Duration::from_millis(1));
    }
    std::fs::write(format!("{}.go", path.display()), b"").unwrap();
    for mut child in children {
        assert!(child.wait().unwrap().success(), "a writer process failed");
    }

    assert_eq!(slot(&path), (CAP, WRITERS * OBSERVATIONS_PER_WRITER));
}
