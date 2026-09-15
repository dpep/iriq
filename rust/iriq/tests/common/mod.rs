//! Shared harness for tests that spawn the `iriq` binary.

use std::path::PathBuf;
use std::process::Command;

/// The built binary, unable to reach the developer's real default corpus: the
/// auto-corpus is off, and HOME / XDG_DATA_HOME point at a scratch directory so
/// a test that turns the corpus back on still writes somewhere disposable.
/// Spawn the binary only through this.
pub fn iriq() -> Command {
    let home = sandbox_home();
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_iriq"));
    cmd.env("IRIQ_NO_CORPUS", "1")
        .env_remove("IRIQ_CORPUS")
        .env("HOME", &home)
        .env("XDG_DATA_HOME", &home);
    cmd
}

pub fn sandbox_home() -> PathBuf {
    let dir =
        PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!("home-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("create sandbox home");
    dir
}
