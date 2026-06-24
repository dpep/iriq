//! End-to-end tests for the `iriq` binary — CLI wiring, output shapes, and
//! exit codes. The library logic is covered by the golden fixtures; this guards
//! the layer between argv and that logic (sections, formats, batch/cluster,
//! corpus subcommands, errors), which had no coverage and is where the
//! corpus-normalize bug hid.

use std::io::Write;
use std::process::{Command, Stdio};

fn run_full(args: &[&str], stdin_data: &str) -> (String, String, bool) {
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
    let o = child.wait_with_output().expect("wait iriq");
    (
        String::from_utf8(o.stdout).unwrap(),
        String::from_utf8(o.stderr).unwrap(),
        o.status.success(),
    )
}

fn run(args: &[&str], stdin_data: &str) -> String {
    let (out, err, ok) = run_full(args, stdin_data);
    assert!(ok, "iriq {args:?} failed: {err}");
    out
}

/// Liveness: `-n` emits each IRI as it arrives, not after EOF. With stdin held
/// open, the first normalized line must appear; a slurping implementation would
/// block on `read_to_string` and print nothing.
#[test]
fn sections_stream_before_stdin_closes() {
    use std::io::{BufRead, BufReader};

    let mut child = Command::new(env!("CARGO_BIN_EXE_iriq"))
        .arg("-n")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn iriq");
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(b"https://foo.com/users/1\n").unwrap();
    stdin.flush().unwrap();
    // keep `stdin` open — do not drop it yet.

    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        let _ = BufReader::new(stdout).read_line(&mut line);
        let _ = tx.send(line);
    });

    let line = rx
        .recv_timeout(std::time::Duration::from_secs(5))
        .expect("no output before stdin closed — -n is not streaming");
    assert!(line.contains("{user_id}"), "got: {line:?}");

    drop(stdin); // EOF → child exits
    let _ = child.wait();
}

fn corpus_with(tag: &str, urls: &str) -> String {
    let p = std::env::temp_dir().join(format!("iriq_e2e_{}_{}.json", std::process::id(), tag));
    let _ = std::fs::remove_file(&p);
    let cp = p.to_str().unwrap().to_string();
    run(&["--corpus", &cp], urls); // observe + save
    cp
}

// ── sections ────────────────────────────────────────────────────────────────

#[test]
fn canonical_vs_normalize() {
    // -c cleans the URL but keeps the specifics; -n erases them into a shape.
    assert_eq!(
        run(&["-c", "HTTP://Foo.com:80/pull/42"], "").trim(),
        "http://foo.com/pull/42"
    );
    let norm = run(&["-n", "HTTP://Foo.com:80/pull/42"], "");
    assert!(
        norm.contains("/pull/{"),
        "expected a placeholder, got: {norm}"
    );
    assert!(
        !norm.contains("/pull/42"),
        "normalize should not keep the literal: {norm}"
    );
}

#[test]
fn default_emits_parse_and_normalize() {
    let out = run(&["https://foo.com/users/123"], "");
    assert!(out.contains("# parse"), "{out}");
    assert!(out.contains("# normalize"), "{out}");
    assert!(out.contains("https://foo.com/users/{user_id}"), "{out}");
}

#[test]
fn explain_shows_per_segment_trace() {
    let out = run(&["-e", "https://foo.com/users/123"], "");
    assert!(out.contains("{user_id}"), "{out}");
    assert!(out.contains("path:"), "{out}");
    assert!(out.contains("integer"), "{out}");
}

// ── output formats ───────────────────────────────────────────────────────────

#[test]
fn parse_json_shape() {
    let out = run(&["-p", "-j", "https://foo.com/users/123"], "");
    let v: serde_json::Value = serde_json::from_str(&out).expect("valid json");
    assert_eq!(v["kind"], "url");
    assert_eq!(v["host"], "foo.com");
    assert_eq!(v["path_segments"], serde_json::json!(["users", "123"]));
}

#[test]
fn multi_section_json_has_ordered_keys() {
    let out = run(&["-pn", "-j", "https://foo.com/users/123"], "");
    let v: serde_json::Value = serde_json::from_str(&out).expect("valid json");
    assert!(v.get("parse").is_some(), "{out}");
    assert_eq!(v["normalize"], "https://foo.com/users/{user_id}");
}

#[test]
fn ndjson_emits_one_object_per_line() {
    let out = run(&["-J", "-n", "https://foo.com/users/123"], "");
    for line in out.lines().filter(|l| !l.is_empty()) {
        serde_json::from_str::<serde_json::Value>(line).expect("each line is json");
    }
    assert!(out.contains("{user_id}"), "{out}");
}

// ── batch / cluster ──────────────────────────────────────────────────────────

#[test]
fn batch_lists_extracted_urls() {
    let out = run(&[], "see https://a.com/x and b.com/y\n");
    let lines: Vec<&str> = out.lines().filter(|l| !l.is_empty()).collect();
    assert_eq!(lines, vec!["https://a.com/x", "https://b.com/y"]);
}

#[test]
fn large_batch_switches_to_cluster_view() {
    let urls: String = (1..=12)
        .map(|i| format!("https://foo.com/users/{i}\n"))
        .collect();
    let out = run(&[], &urls);
    assert!(
        out.contains("[12] foo.com"),
        "expected one cluster of 12: {out}"
    );
    assert!(out.contains("/users/{user_id}"), "{out}");
}

#[test]
fn host_registrable_collapses_subdomains() {
    let urls: String = (1..=6)
        .map(|i| format!("https://api.foo.com/users/{i}\nhttps://app.foo.com/users/{i}\n"))
        .collect();
    let cp = std::env::temp_dir().join(format!("iriq_e2e_{}_reg.json", std::process::id()));
    let _ = std::fs::remove_file(&cp);
    let cps = cp.to_str().unwrap();
    run(&["--host", "registrable", "--corpus", cps], &urls);
    let stats = run(&["--corpus", cps, "--stats"], "");
    assert!(stats.contains("foo.com"), "{stats}");
    assert!(
        !stats.contains("api.foo.com"),
        "subdomains should collapse: {stats}"
    );
    let _ = std::fs::remove_file(&cp);
}

// ── corpus subcommands ───────────────────────────────────────────────────────

#[test]
fn stats_reports_observations_and_shapes() {
    let urls: String = (1..=12)
        .map(|i| format!("https://foo.com/users/{i}\n"))
        .collect();
    let cp = corpus_with("stats", &urls);
    let out = run(&["--corpus", &cp, "--stats"], "");
    assert!(out.contains("observations:"), "{out}");
    assert!(out.contains("clusters:"), "{out}");
    assert!(out.contains("top shapes:"), "{out}");
    let _ = std::fs::remove_file(&cp);
}

#[test]
fn propose_recognizers_runs() {
    let urls: String = (1..=12)
        .map(|i| format!("https://foo.com/users/{i}\n"))
        .collect();
    let cp = corpus_with("propose", &urls);
    let (out, _err, ok) = run_full(&["--corpus", &cp, "--propose-recognizers"], "");
    assert!(ok);
    assert!(out.to_lowercase().contains("proposal"), "{out}");
    let _ = std::fs::remove_file(&cp);
}

#[test]
fn cross_host_shapes_runs() {
    let urls = "https://a.com/users/1\nhttps://b.com/users/2\nhttps://c.com/users/3\n";
    let cp = corpus_with("crosshost", urls);
    let out = run(
        &["--corpus", &cp, "--cross-host-shapes", "--min-hosts", "2"],
        "",
    );
    assert!(out.contains("hosts"), "{out}");
    let _ = std::fs::remove_file(&cp);
}

#[test]
fn reinfer_runs() {
    let urls: String = (1..=12)
        .map(|i| format!("https://foo.com/users/{i}\n"))
        .collect();
    let cp = corpus_with("reinfer", &urls);
    let out = run(&["--corpus", &cp, "--reinfer"], "");
    assert!(out.contains("reinferred"), "{out}");
    let _ = std::fs::remove_file(&cp);
}

// ── errors & meta ────────────────────────────────────────────────────────────

#[test]
fn bad_input_exits_nonzero() {
    let (_out, err, ok) = run_full(&["%%%"], "");
    assert!(!ok, "expected failure exit");
    assert!(err.contains("parse error"), "{err}");
}

#[test]
fn version_matches_crate() {
    assert_eq!(run(&["--version"], "").trim(), iriq::VERSION);
}

#[test]
fn help_shows_usage() {
    let out = run(&["--help"], "");
    assert!(out.contains("Usage: iriq"), "{out}");
    assert!(out.contains("--normalize"), "{out}");
}
