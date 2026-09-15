//! CLI end-to-end: `iriq -n --corpus <path>` must apply corpus-informed
//! normalization, not mechanical. Regression guard for the bug where the CLI
//! observed into the corpus but normalized while ignoring it.

mod common;

use std::io::Write;
use std::process::Stdio;

fn run(args: &[&str], stdin_data: &str) -> String {
    let mut child = common::iriq()
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

/// Pipe mode observes each IRI and then renders it from the corpus as it stands,
/// so a cold corpus prints literals until the evidence for a placeholder exists.
#[test]
fn cli_pipe_normalize_renders_from_the_corpus_so_far() {
    let corpus =
        std::env::temp_dir().join(format!("iriq_cli_pipe_so_far_{}.json", std::process::id()));
    let cp = corpus.to_str().unwrap();
    let _ = std::fs::remove_file(&corpus);

    let urls: String = NAMES
        .iter()
        .map(|n| format!("https://foo.com/users/{n}/profile\n"))
        .collect();
    let out = run(&["-n", "--corpus", cp], &urls);

    // Until the slot has 5 observations it prints as -C would; the fifth
    // distinct name is the first with evidence that the slot is variable.
    let expected: String = NAMES
        .iter()
        .enumerate()
        .map(|(i, n)| match i {
            0..4 => format!("https://foo.com/users/{n}/profile\n"),
            _ => "https://foo.com/users/{user}/profile\n".to_string(),
        })
        .collect();
    assert_eq!(out, expected);
    let _ = std::fs::remove_file(&corpus);
}

#[test]
fn cli_normalize_without_corpus_is_mechanical() {
    // No corpus → a literal slot stays literal.
    let out = run(&["-n", "https://foo.com/users/zoe/profile"], "");
    assert_eq!(out.trim(), "https://foo.com/users/zoe/profile");
}

/// The harness guard: even with the auto-corpus re-enabled, the default corpus
/// lands in the sandbox home, never the developer's real one. Only this test
/// creates a corpus there, so the "created" notice always appears.
#[test]
fn harness_confines_the_default_corpus_to_the_sandbox() {
    let home = common::sandbox_home();
    let out = common::iriq()
        .env_remove("IRIQ_NO_CORPUS")
        .args(["-n", "https://foo.com/users/1"])
        .output()
        .expect("run iriq");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "{stderr}");
    assert!(
        stderr.contains(&format!("created corpus at {}", home.display())),
        "default corpus escaped the sandbox: {stderr}"
    );
}

/// `--reset` names the default path without creating anything, so each XDG
/// case can be checked against its own scratch home.
fn default_path_under(case: &str, xdg: Option<&str>) -> (std::path::PathBuf, String) {
    let home = common::sandbox_home().join(case);
    std::fs::create_dir_all(&home).unwrap();
    let mut cmd = common::iriq();
    cmd.env("HOME", &home).arg("--reset");
    match xdg {
        Some(v) => cmd.env("XDG_DATA_HOME", v),
        None => cmd.env_remove("XDG_DATA_HOME"),
    };
    let out = cmd.output().expect("run iriq");
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    assert!(out.status.success(), "{stderr}");
    (home, stderr)
}

#[cfg(not(windows))]
#[test]
fn default_corpus_follows_xdg_data_home_else_local_share() {
    let name = if cfg!(feature = "sqlite") {
        "default.db"
    } else {
        "default.json"
    };
    let notice = |p: std::path::PathBuf| format!("iriq: no corpus to reset at {}\n", p.display());

    let (home, stderr) = default_path_under("xdg-unset", None);
    assert_eq!(stderr, notice(home.join(".local/share/iriq").join(name)));

    let (home, stderr) = default_path_under("xdg-empty", Some(""));
    assert_eq!(stderr, notice(home.join(".local/share/iriq").join(name)));

    let xdg = common::sandbox_home().join("xdg-set-data");
    let (_, stderr) = default_path_under("xdg-set", xdg.to_str());
    assert_eq!(stderr, notice(xdg.join("iriq").join(name)));
}
