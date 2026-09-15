//! Per-IRI sections stream with a corpus too: each chunk of input is observed
//! in one transaction and printed only after that transaction commits.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdout, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

fn scratch(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("streaming-{}-{name}", std::process::id()))
}

fn spawn_normalize(corpus: &Path) -> Child {
    common::iriq()
        .args(["-n", "--corpus"])
        .arg(corpus)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn iriq")
}

/// The child's stdout lines, read on a thread so a test fails instead of hanging.
fn lines_of(stdout: ChildStdout) -> Receiver<String> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    rx
}

/// A hang guard, not a timing assertion.
fn next_line(lines: &Receiver<String>, missing: &str) -> String {
    lines
        .recv_timeout(Duration::from_secs(20))
        .unwrap_or_else(|_| panic!("{missing}"))
}

#[test]
fn normalize_with_a_corpus_prints_each_line_before_the_next_arrives() {
    let corpus = scratch("live.json");
    let _ = std::fs::remove_file(&corpus);
    let mut child = spawn_normalize(&corpus);
    let mut stdin = child.stdin.take().expect("piped stdin");
    let lines = lines_of(child.stdout.take().expect("piped stdout"));

    writeln!(stdin, "https://foo.com/users/1").unwrap();
    let first = next_line(&lines, "line 1 was not printed before line 2 was written");
    assert!(first.starts_with("https://foo.com/users/"), "{first}");

    writeln!(stdin, "https://foo.com/users/2").unwrap();
    let second = next_line(&lines, "line 2 was not printed");
    assert!(second.starts_with("https://foo.com/users/"), "{second}");

    drop(stdin);
    assert!(child.wait().expect("wait iriq").success());
    let _ = std::fs::remove_file(&corpus);
}

#[test]
#[cfg(feature = "sqlite")]
fn a_killed_stream_keeps_every_line_it_printed() {
    let corpus = scratch("killed.db");
    for side in ["", "-wal", "-shm"] {
        let mut p = corpus.clone().into_os_string();
        p.push(side);
        let _ = std::fs::remove_file(p);
    }
    let mut child = spawn_normalize(&corpus);
    let mut stdin = child.stdin.take().expect("piped stdin");
    let lines = lines_of(child.stdout.take().expect("piped stdout"));

    writeln!(stdin, "https://foo.com/users/1").unwrap();
    next_line(&lines, "line 1 was not printed");
    // SIGKILL: no save, no close — only what already committed survives.
    child.kill().expect("kill iriq");
    child.wait().expect("wait iriq");
    drop(stdin);

    let stats = common::iriq()
        .args(["--stats", "--json", "--corpus"])
        .arg(&corpus)
        .stdin(Stdio::null())
        .output()
        .expect("run iriq --stats");
    let v: serde_json::Value = serde_json::from_slice(&stats.stdout).expect("stats json");
    assert!(v["observations"].as_u64().unwrap_or(0) >= 1, "{v}");
}
