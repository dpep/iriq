//! A write the corpus can't make is an error, never a silent no-op: a cron job
//! pointed at a read-only corpus must fail loudly, not exit 0 having kept nothing.
#![cfg(all(unix, feature = "sqlite"))]

mod common;

use iriq::{Corpus, Error};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Stdio;

/// A SQLite corpus holding one observation, then made read-only. `None` when
/// the permission isn't enforced (e.g. running as root).
fn read_only_corpus(name: &str) -> Option<PathBuf> {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("read-only-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("c.db");
    let mut c = Corpus::open(&path).unwrap();
    c.observe("https://x.com/users/1").unwrap();
    c.close().unwrap();
    drop(c);
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o444)).unwrap();
    if std::fs::OpenOptions::new().write(true).open(&path).is_ok() {
        return None;
    }
    Some(path)
}

#[test]
fn observing_into_a_read_only_corpus_is_an_error_naming_it() {
    let Some(path) = read_only_corpus("lib") else {
        return;
    };
    let mut c = Corpus::open(&path).expect("a read-only corpus still opens for reading");
    let err = c
        .observe("https://x.com/users/2")
        .expect_err("observe into a read-only corpus");
    assert!(matches!(err, Error::Sqlite { .. }), "{err:?}");
    assert!(err.to_string().contains(path.to_str().unwrap()), "{err}");
    assert_eq!(c.observed_iri_count().unwrap(), 1);
}

#[test]
fn a_failed_batch_is_an_error_and_keeps_nothing() {
    let Some(path) = read_only_corpus("batch") else {
        return;
    };
    let mut c = Corpus::open(&path).unwrap();
    let result = c.batch(|c| {
        c.observe("https://x.com/users/2")?;
        c.observe("https://x.com/users/3")
    });
    assert!(result.is_err(), "batch into a read-only corpus succeeded");
    assert_eq!(c.observed_iri_count().unwrap(), 1);
}

#[test]
fn cli_piped_ingest_into_a_read_only_corpus_exits_nonzero() {
    let Some(path) = read_only_corpus("cli") else {
        return;
    };
    let mut child = common::iriq()
        .arg("--corpus")
        .arg(&path)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"https://x.com/users/2\n")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        !out.status.success(),
        "exit 0 with nothing written: {stderr}"
    );
    assert!(
        stderr.contains(&format!("iriq: corpus {}: ", path.display())),
        "{stderr}"
    );
}

#[test]
fn cli_single_input_into_a_read_only_corpus_exits_nonzero() {
    let Some(path) = read_only_corpus("cli-single") else {
        return;
    };
    let out = common::iriq()
        .arg("--corpus")
        .arg(&path)
        .args(["-n", "https://x.com/users/2"])
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        !out.status.success(),
        "exit 0 with nothing written: {stderr}"
    );
    assert!(
        stderr.contains(&format!("iriq: corpus {}: ", path.display())),
        "{stderr}"
    );
}
