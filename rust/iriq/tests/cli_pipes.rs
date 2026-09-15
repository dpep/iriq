//! What iriq does when stdout stops accepting output. A reader that goes away
//! (`iriq -n | head -1`) ends iriq promptly and quietly with the shell's SIGPIPE
//! status, as Ruby's CLI does. Other stdout failures are unit-tested in main.rs:
//! std treats writes to a closed or read-only stdout (EBADF) as success, so a
//! spawned process can't be made to hit one portably.

mod common;

use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

/// Held while this binary starts any process. Without pipe2 (macOS), std
/// creates a child's stdio pipe and marks it close-on-exec in two steps; a
/// test spawning on another thread in between gives its child our stdout's
/// read end, so iriq's writes succeed instead of failing with EPIPE.
static SPAWN: Mutex<()> = Mutex::new(());

fn spawn(cmd: &mut Command) -> Child {
    let _one_at_a_time = SPAWN.lock().unwrap_or_else(PoisonError::into_inner);
    cmd.spawn().expect("spawn iriq")
}

fn output(cmd: &mut Command) -> Output {
    let _one_at_a_time = SPAWN.lock().unwrap_or_else(PoisonError::into_inner);
    cmd.output().expect("run iriq")
}

/// A hang guard, not a timing assertion: a process that ignores its closed
/// stdout never exits, so the test fails here instead of hanging.
fn exit_status(child: &mut Child) -> ExitStatus {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if let Some(status) = child.try_wait().expect("poll iriq") {
            return status;
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            panic!("iriq kept running after stdout closed");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn stderr_of(child: &mut Child) -> String {
    let mut s = String::new();
    child
        .stderr
        .take()
        .expect("piped stderr")
        .read_to_string(&mut s)
        .expect("read stderr");
    s
}

#[test]
fn a_closed_reader_ends_a_live_stream() {
    // `tail -f log | iriq -n | head -1`: stdin stays open, so only the failed
    // write of the next line can end the process.
    let mut child = spawn(
        common::iriq()
            .arg("-n")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()),
    );
    let mut stdin = child.stdin.take().expect("piped stdin");
    writeln!(stdin, "https://foo.com/users/1").unwrap();

    let mut first = String::new();
    BufReader::new(child.stdout.take().expect("piped stdout"))
        .read_line(&mut first)
        .unwrap();
    assert_eq!(first, "https://foo.com/users/{user_id}\n");
    // The reader is dropped: stdout is now a broken pipe.

    writeln!(stdin, "https://foo.com/users/2").unwrap();
    let status = exit_status(&mut child);
    assert_eq!(status.code(), Some(141), "{status:?}");
    assert_eq!(stderr_of(&mut child), "");
    drop(stdin);
}

#[test]
fn a_closed_reader_ends_the_cluster_view_quietly() {
    let mut child = spawn(
        common::iriq()
            .arg("cluster")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()),
    );
    drop(child.stdout.take());
    let urls: String = (1..=50)
        .map(|i| format!("https://h{i}.com/users/{i}\n"))
        .collect();
    let mut stdin = child.stdin.take().expect("piped stdin");
    stdin.write_all(urls.as_bytes()).unwrap();
    drop(stdin);

    let status = exit_status(&mut child);
    assert_eq!(status.code(), Some(141), "{status:?}");
    assert_eq!(stderr_of(&mut child), "");
}

#[test]
fn a_closed_reader_keeps_what_the_corpus_observed() {
    let corpus = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("pipes-corpus-{}.json", std::process::id()));
    let _ = std::fs::remove_file(&corpus);

    let mut child = spawn(
        common::iriq()
            .args(["-n", "--corpus"])
            .arg(&corpus)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null()),
    );
    drop(child.stdout.take());
    let mut stdin = child.stdin.take().expect("piped stdin");
    stdin
        .write_all(b"https://foo.com/users/1\nhttps://foo.com/users/2\n")
        .unwrap();
    drop(stdin);
    let status = exit_status(&mut child);
    assert_eq!(status.code(), Some(141), "{status:?}");

    let stats = output(
        common::iriq()
            .args(["--stats", "--json", "--corpus"])
            .arg(&corpus)
            .stdin(Stdio::null()),
    );
    let v: serde_json::Value = serde_json::from_slice(&stats.stdout).expect("stats json");
    assert_eq!(v["observations"], 2, "{v}");
    let _ = std::fs::remove_file(&corpus);
}
