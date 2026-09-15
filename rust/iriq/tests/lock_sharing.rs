//! Processes share a corpus's write lock: while a long `--reinfer` or
//! `cluster` ingest runs, another process's writer keeps committing instead
//! of waiting it out (or giving up).
#![cfg(feature = "sqlite")]

mod common;

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};

// Enough work to outlast several of the writer's turns in either profile.
const LONG: usize = if cfg!(debug_assertions) {
    40_000
} else {
    400_000
};

fn scratch(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("lock-sharing-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn url(i: usize) -> String {
    format!(
        "https://r{}.com/items/{i}/tags/t{}?page={}",
        i % 5,
        i % 97,
        i % 4
    )
}

fn spawn_long(args: &[&str], corpus: &Path) -> Child {
    common::iriq()
        .args(args)
        .arg("--corpus")
        .arg(corpus)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

fn assert_succeeds(child: Child, what: &str) {
    let out = child.wait_with_output().unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "{what} failed: {stderr}");
}

/// Feeds a `-c` writer one line at a time; it echoes a line only once the
/// line is committed. Answers how many lines committed while `long` was still
/// running, stopping at `enough`.
fn commits_while_running(long: &mut Child, corpus: &Path, enough: usize) -> usize {
    let mut writer = common::iriq()
        .args(["-c", "--corpus"])
        .arg(corpus)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = writer.stdin.take().unwrap();
    let mut echoes = BufReader::new(writer.stdout.take().unwrap());
    let mut during = 0;
    let mut line = String::new();
    for i in 0.. {
        if during == enough || long.try_wait().unwrap().is_some() {
            break;
        }
        writeln!(stdin, "https://writer.example.com/tail/{i}").unwrap();
        line.clear();
        if echoes.read_line(&mut line).unwrap() == 0 {
            break;
        }
        if long.try_wait().unwrap().is_none() {
            during += 1;
        }
    }
    drop(stdin);
    assert_succeeds(writer, "the writer");
    during
}

#[test]
fn a_writer_commits_while_a_long_reinfer_replays() {
    let corpus = scratch("reinfer").join("c.db");
    iriq::Corpus::open(&corpus).unwrap().close().unwrap();
    // A log with no views yet: reinfer builds them all.
    let mut conn = rusqlite::Connection::open(&corpus).unwrap();
    let tx = conn.transaction().unwrap();
    for i in 0..LONG {
        tx.execute(
            "INSERT INTO observed_iris (canonical) VALUES (?)",
            [iriq::parse(&url(i)).unwrap().canonical()],
        )
        .unwrap();
    }
    tx.commit().unwrap();

    let mut reinfer = spawn_long(&["--reinfer"], &corpus);
    // Holding the lock, reinfer would let the writer commit at most the
    // lines it squeezed in before reinfer began.
    let during = commits_while_running(&mut reinfer, &corpus, 20);
    assert_succeeds(reinfer, "reinfer");
    assert_eq!(during, 20, "the writer waited out the reinfer");
}

#[test]
fn a_writer_commits_while_a_long_ingest_runs() {
    let dir = scratch("ingest");
    let corpus = dir.join("c.db");
    let input = dir.join("urls.txt");
    let urls: String = (0..LONG).map(|i| url(i) + "\n").collect();
    std::fs::write(&input, urls).unwrap();

    let mut ingest = spawn_long(&["cluster", input.to_str().unwrap()], &corpus);
    // Handshake: the ingest has committed a turn, so it is past reading its
    // input and into the writes that hold the lock.
    let conn = rusqlite::Connection::open(&corpus).unwrap();
    conn.busy_timeout(std::time::Duration::from_secs(10))
        .unwrap();
    let committed = || -> i64 {
        conn.query_row("SELECT COUNT(*) FROM observed_iris", [], |r| r.get(0))
            .unwrap_or(0)
    };
    while committed() == 0 && ingest.try_wait().unwrap().is_none() {
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let during = commits_while_running(&mut ingest, &corpus, 3);
    assert_succeeds(ingest, "the ingest");
    assert_eq!(during, 3, "the writer waited out the ingest");
}
