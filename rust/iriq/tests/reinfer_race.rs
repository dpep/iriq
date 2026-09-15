//! `--reinfer` rebuilds a corpus's views from its observation log. It must be
//! atomic: writers committing while it runs can't leave views that disagree
//! with the log, nor a replay that dies part-way after its clear committed.
#![cfg(feature = "sqlite")]

mod common;

use serde_json::Value;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::Duration;

const SEEDED: usize = 1000;
const TRICKLED: usize = 3000;
const WRITERS: usize = 2;
const ROUNDS: usize = 2;

fn url(i: usize) -> String {
    format!("https://r{}.com/items/{i}?page={}\n", i % 5, i % 4)
}

fn iriq_ok(args: &[&str], corpus: &Path) -> String {
    let out = common::iriq()
        .args(args)
        .arg("--corpus")
        .arg(corpus)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "iriq {args:?}: {stderr}");
    String::from_utf8(out.stdout).unwrap()
}

/// Every view the CLI shows, clusters in key order (a replay may renumber
/// first-seen order among equal counts).
fn views(corpus: &Path) -> Value {
    let stats: Value = serde_json::from_str(&iriq_ok(&["--stats", "--json"], corpus)).unwrap();
    let mut clusters: Vec<Value> =
        serde_json::from_str(&iriq_ok(&["cluster", "--json"], corpus)).unwrap();
    clusters.sort_by(|a, b| a["key"].as_str().cmp(&b["key"].as_str()));
    serde_json::json!({ "stats": stats, "clusters": clusters })
}

fn writer(corpus: &Path) -> Child {
    common::iriq()
        .args(["-n", "--corpus"])
        .arg(corpus)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap()
}

#[test]
fn reinfer_is_atomic_under_concurrent_writers() {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("reinfer-race-{}", std::process::id()));
    for round in 0..ROUNDS {
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let corpus = dir.join("c.db");

        let mut seed = writer(&corpus);
        let lines: String = (0..SEEDED).map(url).collect();
        seed.stdin
            .take()
            .unwrap()
            .write_all(lines.as_bytes())
            .unwrap();
        assert!(seed.wait().unwrap().success());

        // Writers trickle the rest, committing small chunks while reinfer runs.
        let writers: Vec<_> = (0..WRITERS)
            .map(|w| {
                let mut child = writer(&corpus);
                let mut stdin = child.stdin.take().unwrap();
                let feeder = std::thread::spawn(move || {
                    for i in (SEEDED..SEEDED + TRICKLED).filter(|i| i % WRITERS == w) {
                        stdin.write_all(url(i).as_bytes()).unwrap();
                        std::thread::sleep(Duration::from_micros(500));
                    }
                });
                (child, feeder)
            })
            .collect();
        std::thread::sleep(Duration::from_millis(300));
        let reinfer = common::iriq()
            .args(["--reinfer", "--corpus"])
            .arg(&corpus)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        for (mut child, feeder) in writers {
            feeder.join().unwrap();
            assert!(
                child.wait().unwrap().success(),
                "round {round}: a writer failed"
            );
        }
        let stderr = String::from_utf8_lossy(&reinfer.stderr);
        assert!(
            reinfer.status.success(),
            "round {round}: reinfer failed: {stderr}"
        );

        // Writers are done: rebuilding from the log again must change nothing.
        let live = views(&corpus);
        let replayed = iriq_ok(&["--reinfer"], &corpus);
        let total = SEEDED + TRICKLED;
        assert!(
            replayed.starts_with(&format!("reinferred {total} observations")),
            "{replayed}"
        );
        assert_eq!(
            live,
            views(&corpus),
            "round {round}: views disagree with a clean rebuild of the log"
        );
    }
}
