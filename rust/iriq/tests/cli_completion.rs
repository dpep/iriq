//! `iriq completion` — script emission, the $SHELL fallback when no shell
//! argument is given, and the unknown-shell error path (human + JSON envelope).

use std::process::Command;

struct Output {
    stdout: String,
    stderr: String,
    ok: bool,
}

/// Run the binary with an explicit $SHELL for the child (None → unset).
fn run(args: &[&str], shell: Option<&str>) -> Output {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_iriq"));
    cmd.args(args).env("IRIQ_NO_CORPUS", "1");
    match shell {
        Some(s) => cmd.env("SHELL", s),
        None => cmd.env_remove("SHELL"),
    };
    let o = cmd.output().expect("run iriq");
    Output {
        stdout: String::from_utf8(o.stdout).unwrap(),
        stderr: String::from_utf8(o.stderr).unwrap(),
        ok: o.status.success(),
    }
}

#[test]
fn emits_the_bash_script() {
    let o = run(&["completion", "bash"], None);
    assert!(o.ok, "{}", o.stderr);
    assert!(o.stdout.starts_with("# Bash completion"), "{}", o.stdout);
}

#[test]
fn emits_the_zsh_script() {
    let o = run(&["completion", "zsh"], None);
    assert!(o.ok, "{}", o.stderr);
    assert!(o.stdout.starts_with("#compdef iriq"), "{}", o.stdout);
}

#[test]
fn explicit_shell_argument_wins_over_env() {
    let o = run(&["completion", "bash"], Some("/bin/zsh"));
    assert!(o.ok, "{}", o.stderr);
    assert!(o.stdout.starts_with("# Bash completion"), "{}", o.stdout);
}

#[test]
fn no_argument_falls_back_to_shell_env_basename() {
    let o = run(&["completion"], Some("/usr/local/bin/zsh"));
    assert!(o.ok, "{}", o.stderr);
    assert!(o.stdout.starts_with("#compdef iriq"), "{}", o.stdout);
}

#[test]
fn no_argument_and_no_shell_env_defaults_to_bash() {
    let o = run(&["completion"], None);
    assert!(o.ok, "{}", o.stderr);
    assert!(o.stdout.starts_with("# Bash completion"), "{}", o.stdout);
}

#[test]
fn unknown_shell_errors() {
    let o = run(&["completion", "tcsh"], None);
    assert!(!o.ok, "expected failure exit");
    assert!(o.stdout.is_empty(), "{}", o.stdout);
    assert!(o.stderr.contains("unknown shell"), "{}", o.stderr);
}

#[test]
fn unknown_shell_errors_as_json_envelope() {
    let o = run(&["completion", "tcsh", "--json"], None);
    assert!(!o.ok, "expected failure exit");
    let v: serde_json::Value = serde_json::from_str(o.stderr.trim()).expect("json envelope");
    assert_eq!(v["error"]["code"], "unknown_shell", "{}", o.stderr);
    assert!(v["error"]["message"].is_string(), "{}", o.stderr);
}
