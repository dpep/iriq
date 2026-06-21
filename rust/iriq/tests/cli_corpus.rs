//! CLI end-to-end: `iriq -n --corpus <path>` must apply corpus-informed
//! normalization, not mechanical. Regression guard for the bug where the CLI
//! observed into the corpus but normalized while ignoring it.

use std::io::Write;
use std::process::{Command, Stdio};

fn run(args: &[&str], stdin_data: &str) -> String {
    let mut child = Command::new(env!("CARGO_BIN_EXE_iriq"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn iriq");
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stdin_data.as_bytes())
        .unwrap();
    let out = child.wait_with_output().expect("wait iriq");
    assert!(
        out.status.success(),
        "iriq failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap()
}

const NAMES: [&str; 26] = [
    "alice", "bob", "carol", "dave", "eve", "frank", "grace", "heidi", "ivan", "judy", "ken",
    "leo", "mary", "ned", "olive", "peg", "quinn", "rose", "sam", "tom", "uma", "vic", "wade",
    "xena", "yara", "zoe",
];

#[test]
fn cli_normalize_uses_corpus() {
    // JSON corpus so the test doesn't depend on the optional sqlite feature.
    let corpus = std::env::temp_dir().join(format!("iriq_cli_corpus_{}.json", std::process::id()));
    let cp = corpus.to_str().unwrap();
    let _ = std::fs::remove_file(&corpus);

    // Observe 26 distinct literal handles (piped, no arg → batch observe + save).
    let urls: String = NAMES
        .iter()
        .map(|n| format!("https://foo.com/users/{n}/profile\n"))
        .collect();
    run(&["--corpus", cp], &urls);

    // Corpus-informed normalize: the high-cardinality literal slot collapses.
    let out = run(
        &["-n", "--corpus", cp, "https://foo.com/users/zoe/profile"],
        "",
    );
    assert_eq!(out.trim(), "https://foo.com/users/{user}/profile");

    let _ = std::fs::remove_file(&corpus);
}

#[test]
fn cli_normalize_without_corpus_is_mechanical() {
    // No corpus → a literal slot stays literal.
    let out = run(&["-n", "https://foo.com/users/zoe/profile"], "");
    assert_eq!(out.trim(), "https://foo.com/users/zoe/profile");
}
