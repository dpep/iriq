// Rust port of the iriq CLI. Phase 2 scope: corpus persistence (JSON +
// SQLite), --stats, --reinfer, --propose-recognizers, --cross-host-shapes,
// --activate-above, --host, completion. Phase 1 (-n/-c/-p/-e, -j/-J,
// pipe-mode URL list, cluster auto-switch) also covered here.

use iriq::{
    normalize_identifier, parse, trace_identifier, Cluster, Corpus, Extractor, HostStrategy,
    Identifier, ProposalOptions, RecognizerProposal, TraceResult,
};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs::File;
use std::io::{self, BufRead, BufReader, IsTerminal, Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const LARGE_BATCH_THRESHOLD: usize = 10;
const TOP_N_STATS: usize = 10;

// Byte-for-byte copy of the Ruby CLI's USAGE heredoc (lib/iriq/cli.rb) —
// parity-tested by script/cli_parity.sh's "help" scenario.
const USAGE: &str = r#"iriq — find a URL's shape: the route template behind it (e.g. /users/{id}).

Usage: iriq [options] <input>
       iriq [options] < text
       iriq cluster [options] [file]

<input> may be an IRI, a file path (extracted automatically), or piped
text via stdin.

Sections (combine freely):
  -n, --normalize       Shape — variable parts become placeholders
  -c, --canonical       Clean form — tidy scheme/host, keep the values
  -p, --parse           Parsed fields
  -e, --explain         Annotated trace — per-segment notes about why
                        each placeholder / canonical value was chosen

Corpus + stats:
      --corpus PATH     Use a specific corpus file (overrides the default).
                        Extension picks the backend: .db/.sqlite/.sqlite3
                        are SQLite; anything else is JSON.
  -C, --no-corpus       Disable corpus persistence for this invocation.
                        Same as IRIQ_NO_CORPUS=1 in the environment.
      --reset           Delete the corpus database (default path or the
                        one resolved via --corpus / IRIQ_CORPUS) and exit.
      --host MODE       Host-keying strategy for clustering:
                        full (default), registrable (or reg) strips
                        subdomains, none ignores host entirely.
      --stats           Print rolling aggregates
      --reinfer         Replay the source-IRI log through the current
                        classifier + reducers; rebuilds materialized
                        views from scratch.
      --propose-recognizers
                        Scan observed values for shape patterns that
                        recur enough to suggest a new Recognizer.
                        Combine with --json for structured output.
      --cross-host-shapes
                        List route shapes that recur across
                        multiple hosts. Combine with --min-hosts.
      --activate-above F  With --propose-recognizers, promote every
                        proposal at or above CONFIDENCE F into a
                        live Recognizer on the corpus, then
                        reinfer. Confidence integrates coverage
                        and cross-host corroboration.

Environment:
      IRIQ_CORPUS=PATH    Set the corpus path (overrides the default).
      IRIQ_NO_CORPUS=1    Disable the default corpus (equivalent to -C).

Thresholds (apply to --propose-recognizers / --cross-host-shapes):
      --min-observations N  proposal noise floor (default 20)
      --min-coverage F      proposal coverage floor (default 0.7)
      --min-hosts N         proposal: minimum hosts (default 1);
                            cross-host-shapes: minimum hosts to
                            list (default 2)

Other:
  -h, --help            Show this message
  -j, --json            Emit JSON instead of human-readable output
  -J, --ndjson          Newline-delimited JSON (one object per line). Implies --json.
  -N, --no-hints        Use {integer} placeholders instead of {user_id}
      --no-scheme-less  Skip foo.com/path extraction (explicit-scheme only)
  -V, --version         Print version

Subcommands:
  cluster [file]        Force cluster view (default for ≥10 IRIs anyway)
  completion <shell>    Print shell completion script (bash | zsh)

Examples:
  iriq foo.com/users/456
  iriq -n https://foo.com/users/123
  iriq ./access.log                     # auto-detect file → extract URLs
  cat README.md | iriq -n               # one normalized URL per line
  tail -f access.log | iriq -J          # live stream → NDJSON per IRI
  cat README.md | iriq --corpus c.json
"#;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Section {
    Parse,
    Normalize,
    Explain,
    Canonical,
}

impl Section {
    fn name(&self) -> &'static str {
        match self {
            Section::Parse => "parse",
            Section::Normalize => "normalize",
            Section::Explain => "explain",
            Section::Canonical => "canonical",
        }
    }
}

#[derive(Default)]
struct Opts {
    help: bool,
    version: bool,
    json: bool,
    ndjson: bool,
    hints: bool,
    sections: Vec<Section>,
    scheme_less: bool,
    corpus: String,
    no_corpus: bool,
    reset: bool,
    stats: bool,
    reinfer: bool,
    propose: bool,
    cross_host_shapes: bool,
    activate_above: f64,
    propose_min_obs: usize,
    propose_min_coverage: f64,
    min_hosts: usize,
    host_strategy: HostStrategy,
}

fn default_opts() -> Opts {
    Opts {
        hints: true,
        scheme_less: true,
        host_strategy: HostStrategy::Full,
        ..Opts::default()
    }
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let stdout = io::stdout();
    let stderr = io::stderr();
    let stdin = io::stdin();
    ExitCode::from(run(stdin.lock(), stdout.lock(), stderr.lock(), &argv))
}

fn run<R: Read, W: Write, E: Write>(
    mut stdin: R,
    mut stdout: W,
    mut stderr: E,
    argv: &[String],
) -> u8 {
    let (args, opts) = match parse_options(argv) {
        Ok(p) => p,
        Err(e) => {
            return emit_error(
                &mut stderr,
                argv_wants_json(argv),
                "option_error",
                &e,
                "",
                1,
            );
        }
    };
    if opts.help {
        let written = write!(stdout, "{}", USAGE).map(|()| 0);
        return finish(&mut stdout, &mut stderr, opts.json, written);
    }
    if opts.version {
        let written = writeln!(stdout, "{}", iriq::VERSION).map(|()| 0);
        return finish(&mut stdout, &mut stderr, opts.json, written);
    }

    // `completion <shell>` short-circuits.
    if args.first().map(|s| s.as_str()) == Some("completion") {
        let code = cmd_completion(&mut stdout, &mut stderr, &args[1..], opts.json);
        return finish(&mut stdout, &mut stderr, opts.json, code);
    }

    let mut args = args;
    let mut explicit_cluster = false;
    if args.first().map(|s| s.as_str()) == Some("cluster") {
        explicit_cluster = true;
        args.remove(0);
    }

    // A positional that names an existing file is read as a file, so
    // `iriq access.log` works without ./ (it also parses as a host). An
    // argument containing "://" is always an IRI.
    let positional_is_file = args
        .first()
        .is_some_and(|arg| !arg.contains("://") && is_file(arg));

    let piped = !io::stdin().is_terminal();
    let batch_mode = explicit_cluster || positional_is_file || (args.is_empty() && piped);

    // --reset short-circuits: delete the resolved corpus file + SQLite
    // sidecars and exit. Resolves through the same precedence chain as
    // the normal path.
    if opts.reset {
        return cmd_reset(&mut stderr, &opts);
    }

    // Before any corpus is opened, so a typo doesn't create one.
    if let Some(missing) = missing_input_file(args.first(), explicit_cluster) {
        let message = format!("no such file: {missing}");
        return emit_error(&mut stderr, opts.json, "file_not_found", &message, "", 1);
    }

    if args.is_empty() && !batch_mode && !opts.reinfer && !opts.propose && !opts.cross_host_shapes {
        let written = write!(stdout, "{}", USAGE).map(|()| 0);
        return finish(&mut stdout, &mut stderr, opts.json, written);
    }

    let corpus_path = resolve_corpus_path(&opts);
    let mut corpus: Option<Corpus> = None;
    if let Some(ref path) = corpus_path {
        let pre_exists = std::path::Path::new(path).exists();
        if !pre_exists {
            if let Some(parent) = std::path::Path::new(path).parent() {
                if let Err(e) = std::fs::create_dir_all(parent) {
                    let message = format!("corpus {path}: {e}");
                    return emit_error(&mut stderr, opts.json, "corpus_error", &message, "", 1);
                }
            }
        }
        match Corpus::open(path) {
            Ok(mut c) => {
                c.set_host_strategy(opts.host_strategy);
                if !pre_exists {
                    let _ = writeln!(
                        stderr,
                        "iriq: created corpus at {} (disable with --no-corpus or IRIQ_NO_CORPUS=1)",
                        path
                    );
                }
                corpus = Some(c);
            }
            Err(e) => return corpus_error(&mut stderr, opts.json, &e),
        }
    }

    let code = if opts.reinfer {
        cmd_reinfer(&mut stdout, &mut stderr, corpus.as_mut(), &opts)
    } else if opts.propose {
        cmd_propose(&mut stdout, &mut stderr, corpus.as_mut(), &opts)
    } else if opts.cross_host_shapes {
        cmd_cross_host_shapes(&mut stdout, &mut stderr, corpus.as_ref(), &opts)
    } else if batch_mode {
        cmd_batch(
            &mut stdin,
            &mut stdout,
            &mut stderr,
            &args,
            &opts,
            corpus.as_mut(),
            explicit_cluster,
        )
    } else if opts.stats {
        cmd_stats(&mut stdout, &mut stderr, corpus.as_ref(), &opts)
    } else {
        cmd_summary(&mut stdout, &mut stderr, &args, &opts, corpus.as_mut())
    };
    let code = match code {
        Ok(code) => Ok(code),
        Err(Failure::Io(e)) => Err(e),
        Err(Failure::Corpus(e)) => Ok(corpus_error(&mut stderr, opts.json, &e)),
    };

    // Saved even when stdout failed: everything read so far was observed.
    if let Some(mut c) = corpus {
        if let Some(ref path) = corpus_path {
            if let Err(e) = c.save(path) {
                return corpus_error(&mut stderr, opts.json, &e);
            }
        }
        let _ = c.close();
    }
    finish(&mut stdout, &mut stderr, opts.json, code)
}

// Flush what a command wrote and turn a stdout failure into the exit status. A
// reader that went away (`iriq -n | head -1`) ends iriq quietly with the status
// a SIGPIPE death reports, as Ruby's CLI does; anything else is an error.
fn finish<W: Write, E: Write>(
    stdout: &mut W,
    stderr: &mut E,
    json: bool,
    outcome: io::Result<u8>,
) -> u8 {
    match outcome.and_then(|code| stdout.flush().map(|()| code)) {
        Ok(code) => code,
        Err(e) if e.kind() == io::ErrorKind::BrokenPipe => 141,
        Err(e) => emit_error(stderr, json, "stdout_error", &format!("stdout: {e}"), "", 1),
    }
}

// Why a command stopped: stdout failed (see `finish`) or the corpus did. A
// command propagates either with `?`; `run` reports them.
enum Failure {
    Io(io::Error),
    Corpus(iriq::Error),
}

impl From<io::Error> for Failure {
    fn from(e: io::Error) -> Self {
        Failure::Io(e)
    }
}

impl From<iriq::Error> for Failure {
    fn from(e: iriq::Error) -> Self {
        Failure::Corpus(e)
    }
}

// Every corpus failure reads `corpus <path>: <cause>`, code corpus_error, as in
// Ruby. Library errors name what failed and keep the cause in source().
fn corpus_error<E: Write>(stderr: &mut E, json: bool, e: &iriq::Error) -> u8 {
    let message = match std::error::Error::source(e) {
        Some(cause) => format!("{e}: {cause}"),
        None => e.to_string(),
    };
    emit_error(stderr, json, "corpus_error", &message, "", 1)
}

// resolve_corpus_path applies the precedence chain:
//   1. --corpus PATH       — explicit always wins
//   2. --no-corpus / IRIQ_NO_CORPUS=1 — opt out of the default
//   3. IRIQ_CORPUS=PATH    — env override of the default location
//   4. default_corpus_path() — platform-aware location
fn resolve_corpus_path(opts: &Opts) -> Option<String> {
    if !opts.corpus.is_empty() {
        return Some(opts.corpus.clone());
    }
    if opts.no_corpus || env_corpus_disabled() {
        return None;
    }
    let env = std::env::var("IRIQ_CORPUS").unwrap_or_default();
    if !env.is_empty() {
        return Some(env);
    }
    Some(default_corpus_path())
}

// default_corpus_path mirrors the Ruby + Go resolvers — XDG on Linux,
// Apple-style on macOS, %LOCALAPPDATA% on Windows.
fn default_corpus_path() -> String {
    use std::path::PathBuf;
    let base: PathBuf = if cfg!(target_os = "macos") {
        if let Some(home) = std::env::var_os("HOME") {
            PathBuf::from(home)
                .join("Library")
                .join("Application Support")
                .join("iriq")
        } else {
            std::env::temp_dir().join("iriq")
        }
    } else if cfg!(target_os = "windows") {
        let appdata = std::env::var_os("LOCALAPPDATA").or_else(|| {
            std::env::var_os("USERPROFILE").map(|h| {
                PathBuf::from(h)
                    .join("AppData")
                    .join("Local")
                    .into_os_string()
            })
        });
        match appdata {
            Some(v) => PathBuf::from(v).join("iriq"),
            None => std::env::temp_dir().join("iriq"),
        }
    } else {
        // XDG-honoring on Linux + BSD.
        let xdg = std::env::var_os("XDG_DATA_HOME").filter(|v| !v.is_empty());
        match xdg {
            Some(v) => PathBuf::from(v).join("iriq"),
            None => match std::env::var_os("HOME") {
                Some(home) => PathBuf::from(home)
                    .join(".local")
                    .join("share")
                    .join("iriq"),
                None => std::env::temp_dir().join("iriq"),
            },
        }
    };
    // Without the sqlite feature the SQLite backend isn't linked, so the
    // auto-default falls back to the JSON backend rather than naming a file
    // open_storage would reject.
    #[cfg(feature = "sqlite")]
    let name = "default.db";
    #[cfg(not(feature = "sqlite"))]
    let name = "default.json";
    base.join(name).to_string_lossy().into_owned()
}

fn env_corpus_disabled() -> bool {
    match std::env::var("IRIQ_NO_CORPUS") {
        Ok(v) => {
            let lc = v.to_lowercase();
            !lc.is_empty() && lc != "0" && lc != "false" && lc != "no"
        }
        Err(_) => false,
    }
}

fn cmd_reset<W: Write>(stderr: &mut W, opts: &Opts) -> u8 {
    let path = resolve_reset_path(opts);
    let mut removed = 0;
    let named = [
        path.clone(),
        format!("{}-wal", path),
        format!("{}-shm", path),
        format!("{}.tmp", path),
    ]
    .map(PathBuf::from);
    for p in named.into_iter().chain(json_temp_files(Path::new(&path))) {
        if std::fs::remove_file(&p).is_ok() {
            removed += 1;
        }
    }
    if removed == 0 {
        let _ = writeln!(stderr, "iriq: no corpus to reset at {}", path);
    } else {
        let _ = writeln!(stderr, "iriq: reset corpus at {}", path);
    }
    0
}

// resolve_reset_path honors --corpus / IRIQ_CORPUS even under --no-corpus —
// the user is explicitly addressing a stored file, not runtime state.
fn resolve_reset_path(opts: &Opts) -> String {
    if !opts.corpus.is_empty() {
        return opts.corpus.clone();
    }
    let env = std::env::var("IRIQ_CORPUS").unwrap_or_default();
    if !env.is_empty() {
        return env;
    }
    default_corpus_path()
}

// The JSON writer's per-save temp files, `<path>.<pid>.<n>.tmp`; a save that
// dies before its rename leaves one behind.
fn json_temp_files(path: &Path) -> Vec<PathBuf> {
    let (Some(name), Some(dir)) = (path.file_name().and_then(|n| n.to_str()), path.parent()) else {
        return Vec::new();
    };
    let dir = if dir.as_os_str().is_empty() {
        Path::new(".")
    } else {
        dir
    };
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    entries
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.file_name())
        .filter(|file| {
            file.to_str()
                .and_then(|f| {
                    f.strip_prefix(name)?
                        .strip_prefix('.')?
                        .strip_suffix(".tmp")
                })
                .and_then(|counters| counters.split_once('.'))
                .is_some_and(|(pid, n)| digits(pid) && digits(n))
        })
        .map(|file| dir.join(file))
        .collect()
}

fn parseable_iri(s: &str) -> bool {
    parse(s).is_ok()
}

fn is_file(path: &str) -> bool {
    std::fs::metadata(path).is_ok_and(|m| m.is_file())
}

// The argument iriq would have read as a file but can't find: anything after
// `cluster`, or a /, ./, ../ path that isn't an IRI.
fn missing_input_file(arg: Option<&String>, explicit_cluster: bool) -> Option<&str> {
    let arg = arg?.as_str();
    if arg == "-" || is_file(arg) {
        return None;
    }
    let path_like = ["/", "./", "../"].iter().any(|p| arg.starts_with(p));
    (explicit_cluster || (path_like && !parseable_iri(arg))).then_some(arg)
}

// Input iriq couldn't read. Invalid UTF-8 has its own JSON code, as in Ruby.
fn read_error<E: Write>(stderr: &mut E, json: bool, e: &io::Error) -> u8 {
    let code = match e.kind() {
        io::ErrorKind::InvalidData => "invalid_utf8",
        _ => "read_error",
    };
    emit_error(stderr, json, code, &e.to_string(), "", 1)
}

fn argv_wants_json(argv: &[String]) -> bool {
    argv.iter()
        .any(|a| a == "-j" || a == "--json" || a == "-J" || a == "--ndjson")
}

fn parse_options(argv: &[String]) -> Result<(Vec<String>, Opts), String> {
    let mut opts = default_opts();
    let mut args = Vec::new();
    let mut i = 0;
    while i < argv.len() {
        let a = &argv[i];
        // Handle --flag=value form.
        if let Some(eq) = a.find('=') {
            if a.starts_with("--") {
                let (name, val) = (&a[..eq], &a[eq + 1..]);
                match name {
                    "--corpus" => opts.corpus = val.to_string(),
                    "--host" => {
                        opts.host_strategy =
                            parse_host_strategy(val).ok_or_else(|| host_error(a))?
                    }
                    "--activate-above" => {
                        opts.activate_above = val
                            .parse()
                            .map_err(|e: std::num::ParseFloatError| e.to_string())?
                    }
                    "--min-hosts" => {
                        opts.min_hosts = val
                            .parse()
                            .map_err(|e: std::num::ParseIntError| e.to_string())?
                    }
                    "--min-observations" => {
                        opts.propose_min_obs = val
                            .parse()
                            .map_err(|e: std::num::ParseIntError| e.to_string())?
                    }
                    "--min-coverage" => {
                        opts.propose_min_coverage = val
                            .parse()
                            .map_err(|e: std::num::ParseFloatError| e.to_string())?
                    }
                    _ => return Err(format!("invalid option: {}", a)),
                }
                i += 1;
                continue;
            }
        }

        match a.as_str() {
            "--" => {
                args.extend_from_slice(&argv[i + 1..]);
                return Ok((args, opts));
            }
            "-h" | "--help" => opts.help = true,
            "-V" | "--version" => opts.version = true,
            "-j" | "--json" => opts.json = true,
            "-J" | "--ndjson" => {
                opts.json = true;
                opts.ndjson = true;
            }
            "--hints" => opts.hints = true,
            "-N" | "--no-hints" => opts.hints = false,
            "--scheme-less" => opts.scheme_less = true,
            "--no-scheme-less" => opts.scheme_less = false,
            "-p" | "--parse" => opts.sections.push(Section::Parse),
            "-n" | "--normalize" => opts.sections.push(Section::Normalize),
            "-c" | "--canonical" => opts.sections.push(Section::Canonical),
            "-e" | "--explain" => opts.sections.push(Section::Explain),
            "--corpus" => {
                i += 1;
                opts.corpus = argv.get(i).cloned().ok_or("--corpus requires a value")?;
            }
            "-C" | "--no-corpus" => opts.no_corpus = true,
            "--reset" => opts.reset = true,
            "--stats" => opts.stats = true,
            "--reinfer" => opts.reinfer = true,
            "--propose-recognizers" => opts.propose = true,
            "--cross-host-shapes" => opts.cross_host_shapes = true,
            "--activate-above" => {
                i += 1;
                opts.activate_above = argv
                    .get(i)
                    .ok_or("--activate-above requires a value")?
                    .parse()
                    .map_err(|e: std::num::ParseFloatError| e.to_string())?;
            }
            "--host" => {
                i += 1;
                let v = argv.get(i).ok_or("--host requires a value")?;
                opts.host_strategy =
                    parse_host_strategy(v).ok_or_else(|| host_error(&format!("--host {v}")))?;
            }
            "--min-hosts" => {
                i += 1;
                opts.min_hosts = argv
                    .get(i)
                    .ok_or("--min-hosts requires a value")?
                    .parse()
                    .map_err(|e: std::num::ParseIntError| e.to_string())?;
            }
            "--min-observations" => {
                i += 1;
                opts.propose_min_obs = argv
                    .get(i)
                    .ok_or("--min-observations requires a value")?
                    .parse()
                    .map_err(|e: std::num::ParseIntError| e.to_string())?;
            }
            "--min-coverage" => {
                i += 1;
                opts.propose_min_coverage = argv
                    .get(i)
                    .ok_or("--min-coverage requires a value")?
                    .parse()
                    .map_err(|e: std::num::ParseFloatError| e.to_string())?;
            }
            s if s.starts_with("--") => {
                return Err(format!("invalid option: {}", s));
            }
            s if s.starts_with('-') && s.len() > 1 => {
                for ch in s[1..].chars() {
                    match ch {
                        'p' => opts.sections.push(Section::Parse),
                        'n' => opts.sections.push(Section::Normalize),
                        'c' => opts.sections.push(Section::Canonical),
                        'e' => opts.sections.push(Section::Explain),
                        'j' => opts.json = true,
                        'J' => {
                            opts.json = true;
                            opts.ndjson = true;
                        }
                        'N' => opts.hints = false,
                        'C' => opts.no_corpus = true,
                        'h' => opts.help = true,
                        'V' => opts.version = true,
                        _ => return Err(format!("invalid option: -{}", ch)),
                    }
                }
            }
            _ => args.push(a.clone()),
        }
        i += 1;
    }
    Ok((args, opts))
}

fn parse_host_strategy(v: &str) -> Option<HostStrategy> {
    match v.to_lowercase().as_str() {
        "full" => Some(HostStrategy::Full),
        "registrable" | "reg" => Some(HostStrategy::Registrable),
        "none" => Some(HostStrategy::None),
        _ => None,
    }
}

// Ruby's OptionParser names the argument as the user wrote it (`--host bogus`
// or `--host=bogus`), then the accepted modes.
fn host_error(given: &str) -> String {
    format!("invalid argument: {given} (expected full|registrable|reg|none)")
}

// ── Summary mode ────────────────────────────────────────────────────────────

fn cmd_summary<W: Write, E: Write>(
    stdout: &mut W,
    stderr: &mut E,
    args: &[String],
    opts: &Opts,
    corpus: Option<&mut Corpus>,
) -> Result<u8, Failure> {
    if args.is_empty() {
        return Ok(emit_error(
            stderr,
            opts.json,
            "missing_argument",
            "missing argument <input>",
            "",
            1,
        ));
    }
    let iri = match parse(&args[0]) {
        Ok(i) => i,
        Err(e) => {
            return Ok(emit_error(
                stderr,
                opts.json,
                "parse_error",
                e.message(),
                &format!("iriq: {}", e),
                2,
            ));
        }
    };
    // Observe the input, then keep an immutable handle so the Normalize
    // section can use corpus-informed normalization — the whole point of
    // passing --corpus.
    let corpus: Option<&Corpus> = match corpus {
        Some(c) => {
            c.observe_iri(&iri)?;
            Some(&*c)
        }
        None => None,
    };

    let sections = if opts.sections.is_empty() {
        vec![Section::Parse, Section::Normalize]
    } else {
        opts.sections.clone()
    };

    if opts.json {
        if sections.len() == 1 {
            let payload = section_payload(&iri, sections[0], opts, corpus)?;
            write_json(stdout, &payload)?;
        } else {
            // Multi-section JSON: fixed key order parse / canonical / normalize / explain.
            let mut payload = serde_json::Map::new();
            for s in ["parse", "canonical", "normalize", "explain"] {
                if let Some(sec) = sections.iter().find(|sec| sec.name() == s) {
                    payload.insert(s.to_string(), section_payload(&iri, *sec, opts, corpus)?);
                }
            }
            write_json(stdout, &Value::Object(payload))?;
        }
        return Ok(0);
    }

    emit_sections_human(stdout, &iri, &sections, opts, corpus)?;
    Ok(0)
}

// Corpus-informed when a corpus is loaded; mechanical otherwise. This is what
// makes `iriq -n --corpus c.db` reflect observed distributions (e.g. a
// high-cardinality literal slot collapsing to a placeholder).
fn normalize_section(
    iri: &Identifier,
    opts: &Opts,
    corpus: Option<&Corpus>,
) -> iriq::Result<String> {
    match corpus {
        Some(c) => c.normalize_identifier(iri, opts.hints),
        None => Ok(normalize_identifier(iri, opts.hints)),
    }
}

fn section_payload(
    iri: &Identifier,
    sec: Section,
    opts: &Opts,
    corpus: Option<&Corpus>,
) -> iriq::Result<Value> {
    Ok(match sec {
        Section::Parse => identifier_json(iri),
        Section::Canonical => Value::String(iri.canonical()),
        Section::Normalize => Value::String(normalize_section(iri, opts, corpus)?),
        Section::Explain => serde_json::to_value(trace_identifier(iri, opts.hints)).unwrap(),
    })
}

fn identifier_json(iri: &Identifier) -> Value {
    let mut o = serde_json::Map::new();
    o.insert("original".to_string(), Value::String(iri.original.clone()));
    o.insert(
        "kind".to_string(),
        Value::String(iri.kind.as_str().to_string()),
    );
    if !iri.scheme.is_empty() {
        o.insert("scheme".to_string(), Value::String(iri.scheme.clone()));
    }
    if !iri.host.is_empty() {
        o.insert("host".to_string(), Value::String(iri.host.clone()));
    }
    if let Some(port) = iri.port {
        o.insert("port".to_string(), Value::Number(port.into()));
    }
    if !iri.path_segments.is_empty() {
        o.insert(
            "path_segments".to_string(),
            Value::Array(
                iri.path_segments
                    .iter()
                    .map(|s| Value::String(s.clone()))
                    .collect(),
            ),
        );
    }
    if !iri.query_params.is_empty() {
        let mut qp = serde_json::Map::new();
        for (k, v) in iri.query_params.iter_raw() {
            // Ruby: "?flag" is nil (JSON null), "?flag=" is "".
            let val = v.map_or(Value::Null, |v| Value::String(v.to_string()));
            qp.insert(k.to_string(), val);
        }
        o.insert("query_params".to_string(), Value::Object(qp));
    }
    if !iri.fragment.is_empty() {
        o.insert("fragment".to_string(), Value::String(iri.fragment.clone()));
    }
    if !iri.nss.is_empty() {
        o.insert("nss".to_string(), Value::String(iri.nss.clone()));
    }
    o.insert("canonical".to_string(), Value::String(iri.canonical()));
    Value::Object(o)
}

// ── Human renderers ─────────────────────────────────────────────────────────

fn emit_sections_human<W: Write>(
    stdout: &mut W,
    iri: &Identifier,
    sections: &[Section],
    opts: &Opts,
    corpus: Option<&Corpus>,
) -> Result<(), Failure> {
    let multi = sections.len() > 1;
    for (i, sec) in sections.iter().enumerate() {
        if i > 0 {
            writeln!(stdout)?;
        }
        if multi {
            writeln!(stdout, "# {}", sec.name())?;
        }
        match sec {
            Section::Parse => emit_parse_human(stdout, iri)?,
            Section::Canonical => {
                writeln!(stdout, "{}", iri.canonical())?;
            }
            Section::Normalize => {
                writeln!(stdout, "{}", normalize_section(iri, opts, corpus)?)?;
            }
            Section::Explain => {
                emit_explain_human(stdout, &trace_identifier(iri, opts.hints))?;
            }
        }
    }
    Ok(())
}

fn emit_parse_human<W: Write>(stdout: &mut W, iri: &Identifier) -> io::Result<()> {
    writeln!(stdout, "original:      {}", iri.original)?;
    writeln!(stdout, "kind:          {}", iri.kind.as_str())?;
    if !iri.scheme.is_empty() {
        writeln!(stdout, "scheme:        {}", iri.scheme)?;
    }
    if !iri.host.is_empty() {
        writeln!(stdout, "host:          {}", iri.host)?;
    }
    if let Some(port) = iri.port {
        writeln!(stdout, "port:          {}", port)?;
    }
    if !iri.path_segments.is_empty() {
        writeln!(
            stdout,
            "path_segments: {}",
            inspect_strings(&iri.path_segments)
        )?;
    }
    if !iri.query_params.is_empty() {
        // Ruby renders the Hash via #inspect: insertion order, spaced
        // arrows (Ruby 3.4+ style), and nil for valueless params.
        let parts: Vec<String> = iri
            .query_params
            .iter_raw()
            .map(|(k, v)| match v {
                Some(v) => format!("{:?} => {:?}", k, v),
                None => format!("{:?} => nil", k),
            })
            .collect();
        writeln!(stdout, "query_params:  {{{}}}", parts.join(", "))?;
    }
    if !iri.fragment.is_empty() {
        writeln!(stdout, "fragment:      {}", iri.fragment)?;
    }
    if !iri.nss.is_empty() {
        writeln!(stdout, "nss:           {}", iri.nss)?;
    }
    writeln!(stdout, "canonical:     {}", iri.canonical())?;
    Ok(())
}

fn inspect_strings(ss: &[String]) -> String {
    if ss.is_empty() {
        return "[]".to_string();
    }
    let parts: Vec<String> = ss.iter().map(|s| format!("{:?}", s)).collect();
    format!("[{}]", parts.join(", "))
}

fn emit_explain_human<W: Write>(stdout: &mut W, tr: &TraceResult) -> io::Result<()> {
    writeln!(stdout, "{}", tr.normalized)?;
    emit_trace_section(stdout, "path", &tr.path)?;
    if !tr.query.is_empty() {
        emit_trace_section(stdout, "query", &tr.query)?;
    }
    Ok(())
}

fn emit_trace_section<W: Write>(
    stdout: &mut W,
    label: &str,
    rows: &[iriq::TraceRow],
) -> io::Result<()> {
    if rows.is_empty() {
        return Ok(());
    }
    writeln!(stdout)?;
    writeln!(stdout, "{}:", label)?;
    let (mut nw, mut tw, mut ow) = (0usize, 0usize, 0usize);
    for r in rows {
        let l = row_label(r);
        nw = nw.max(l.chars().count());
        tw = tw.max(r.ty.as_str().chars().count());
        ow = ow.max(r.output.chars().count());
    }
    for r in rows {
        let notes = if r.notes.is_empty() {
            String::new()
        } else {
            format!("  ({})", r.notes.join("; "))
        };
        writeln!(
            stdout,
            "  {:<nw$}  {:<tw$}  {:<ow$}{}",
            row_label(r),
            r.ty.as_str(),
            r.output,
            notes,
            nw = nw,
            tw = tw,
            ow = ow,
        )?;
    }
    Ok(())
}

fn row_label(r: &iriq::TraceRow) -> String {
    if !r.name.is_empty() {
        format!("{}={}", r.name, r.value)
    } else {
        r.value.clone()
    }
}

// ── Batch / pipe mode ───────────────────────────────────────────────────────

fn cmd_batch<R: Read, W: Write, E: Write>(
    stdin: &mut R,
    stdout: &mut W,
    stderr: &mut E,
    args: &[String],
    opts: &Opts,
    corpus: Option<&mut Corpus>,
    explicit_cluster: bool,
) -> Result<u8, Failure> {
    // Per-IRI sections (-n/-p/-c/-e) stream, with or without a corpus, so a
    // live `tail -f | iriq -n` prints as lines arrive. The aggregate views
    // below need the whole input first, so they slurp.
    if !opts.sections.is_empty() {
        return stream_per_iri_sections(stdin, stdout, stderr, args, opts, corpus);
    }

    let text = match read_text(stdin, args) {
        Ok(t) => t,
        Err(e) => return Ok(read_error(stderr, opts.json, &e)),
    };
    let mut extractor = Extractor::new();
    extractor.scheme_less = opts.scheme_less;
    let iris = extractor.extract(&text);

    // Feed observations into the corpus when present, else a throwaway one
    // keyed the way --host asks.
    let mut owned_corpus = corpus.is_none().then(|| {
        let mut c = Corpus::new();
        c.set_host_strategy(opts.host_strategy);
        c
    });
    let working: &mut Corpus = match (corpus, &mut owned_corpus) {
        (Some(c), _) => c,
        (None, Some(c)) => c,
        _ => unreachable!(),
    };
    working.batch(|c| {
        for iri in &iris {
            c.observe_iri(iri)?;
        }
        Ok(())
    })?;

    if opts.stats {
        emit_stats(stdout, working, opts)?;
        return Ok(0);
    }
    if explicit_cluster || iris.len() >= LARGE_BATCH_THRESHOLD {
        emit_clusters(stdout, &working.clusters()?, opts)?;
        return Ok(0);
    }
    emit_url_list(stdout, &iris, opts)?;
    Ok(0)
}

fn read_text<R: Read>(stdin: &mut R, args: &[String]) -> std::io::Result<String> {
    if args.is_empty() || args[0] == "-" {
        let mut s = String::new();
        stdin.read_to_string(&mut s)?;
        return Ok(s);
    }
    std::fs::read_to_string(&args[0])
}

// Read size for streamed input. A chunk is every complete line already read,
// so this bounds how many lines share a transaction, not how long output waits.
const CHUNK_BYTES: usize = 64 * 1024;

// Stream the per-IRI sections: a chunk at a time, observe each IRI (when there
// is a corpus), render it from the corpus as it now stands, and print the chunk
// only after its transaction commits, so a killed process never printed a line
// its corpus lost. A wrapping JSON array prints at EOF. Matches whole-text
// extraction exactly: a candidate never spans a newline and extract dedups
// nothing.
fn stream_per_iri_sections<R: Read, W: Write, E: Write>(
    stdin: &mut R,
    stdout: &mut W,
    stderr: &mut E,
    args: &[String],
    opts: &Opts,
    mut corpus: Option<&mut Corpus>,
) -> Result<u8, Failure> {
    let source: Box<dyn Read + '_> = if args.is_empty() || args[0] == "-" {
        Box::new(stdin)
    } else {
        match File::open(&args[0]) {
            Ok(f) => Box::new(f),
            Err(e) => return Ok(read_error(stderr, opts.json, &e)),
        }
    };
    let mut input = LineInput::new(source, opts);
    let mut rendered = Rendered::default();
    let mut line = String::new();
    // Waits for input outside any transaction: a quiet `tail -f` must not hold
    // the corpus's write lock.
    while input.error.is_none() && input.next_line(&mut line) {
        match corpus.as_deref_mut() {
            Some(c) => c.batch(|c| input.chunk(&mut line, Some(c), opts, &mut rendered))?,
            None => input.chunk(&mut line, None, opts, &mut rendered)?,
        }
        stdout.write_all(&rendered.bytes)?;
        stdout.flush()?;
        rendered.bytes.clear();
    }
    if let Some(e) = input.error {
        return Ok(read_error(stderr, opts.json, &e));
    }
    if opts.json && !opts.ndjson {
        emit_json_array(stdout, &rendered.json, opts)?;
    }
    Ok(0)
}

struct LineInput<'a> {
    reader: BufReader<Box<dyn Read + 'a>>,
    extractor: Extractor,
    error: Option<io::Error>,
}

impl<'a> LineInput<'a> {
    fn new(source: Box<dyn Read + 'a>, opts: &Opts) -> Self {
        let mut extractor = Extractor::new();
        extractor.scheme_less = opts.scheme_less;
        LineInput {
            reader: BufReader::with_capacity(CHUNK_BYTES, source),
            extractor,
            error: None,
        }
    }

    // The next line, waiting for it if need be; false at EOF or on a read
    // error, which is kept in `error`.
    fn next_line(&mut self, line: &mut String) -> bool {
        line.clear();
        match self.reader.read_line(line) {
            Ok(n) => n > 0,
            Err(e) => {
                self.error = Some(e);
                false
            }
        }
    }

    // Observes and renders `line`, then every further complete line already
    // buffered. Never waits for input: this runs inside the chunk's transaction.
    fn chunk(
        &mut self,
        line: &mut String,
        mut corpus: Option<&mut Corpus>,
        opts: &Opts,
        rendered: &mut Rendered,
    ) -> iriq::Result<()> {
        loop {
            for iri in self.extractor.extract(line.as_str()) {
                if let Some(c) = corpus.as_deref_mut() {
                    c.observe_iri(&iri)?;
                }
                rendered.push(&iri, opts, corpus.as_deref())?;
            }
            if !self.reader.buffer().contains(&b'\n') || !self.next_line(line) {
                return Ok(());
            }
        }
    }
}

// Output for IRIs whose chunk hasn't committed yet, plus the elements of a
// JSON array, which prints whole at EOF.
#[derive(Default)]
struct Rendered {
    bytes: Vec<u8>,
    json: Vec<Value>,
    count: usize,
}

impl Rendered {
    fn push(&mut self, iri: &Identifier, opts: &Opts, corpus: Option<&Corpus>) -> iriq::Result<()> {
        if opts.json && !opts.ndjson {
            self.json.push(iri_payload(iri, opts, corpus)?);
        } else {
            match emit_one_iri_section(&mut self.bytes, iri, self.count, opts, corpus) {
                Ok(()) => {}
                Err(Failure::Corpus(e)) => return Err(e),
                Err(Failure::Io(e)) => unreachable!("writing to a Vec cannot fail: {e}"),
            }
        }
        self.count += 1;
        Ok(())
    }
}

// One IRI's JSON: the bare value for a single section, else an object keyed
// parse / canonical / normalize / explain.
fn iri_payload(iri: &Identifier, opts: &Opts, corpus: Option<&Corpus>) -> iriq::Result<Value> {
    if opts.sections.len() == 1 {
        return section_payload(iri, opts.sections[0], opts, corpus);
    }
    let mut m = serde_json::Map::new();
    for s in ["parse", "canonical", "normalize", "explain"] {
        if let Some(sec) = opts.sections.iter().find(|sec| sec.name() == s) {
            m.insert(s.to_string(), section_payload(iri, *sec, opts, corpus)?);
        }
    }
    Ok(Value::Object(m))
}

// Emit one IRI's sections in human or NDJSON form (i is its index in the whole
// stream, controlling the blank-line separator).
fn emit_one_iri_section<W: Write>(
    stdout: &mut W,
    iri: &Identifier,
    i: usize,
    opts: &Opts,
    corpus: Option<&Corpus>,
) -> Result<(), Failure> {
    if opts.ndjson {
        let payload = iri_payload(iri, opts, corpus)?;
        writeln!(stdout, "{}", serde_json::to_string(&payload).unwrap())?;
        return Ok(());
    }

    if opts.sections.len() == 1
        && (opts.sections[0] == Section::Normalize || opts.sections[0] == Section::Canonical)
    {
        match opts.sections[0] {
            Section::Canonical => {
                writeln!(stdout, "{}", iri.canonical())?;
            }
            Section::Normalize => {
                writeln!(stdout, "{}", normalize_section(iri, opts, corpus)?)?;
            }
            _ => {}
        }
        return Ok(());
    }

    if i > 0 {
        writeln!(stdout)?;
    }
    writeln!(stdout, "# {}", iri.canonical())?;
    for (j, sec) in opts.sections.iter().enumerate() {
        if j > 0 {
            writeln!(stdout)?;
        }
        match sec {
            Section::Parse => emit_parse_human(stdout, iri)?,
            Section::Canonical => {
                writeln!(stdout, "{}", iri.canonical())?;
            }
            Section::Normalize => {
                writeln!(stdout, "{}", normalize_section(iri, opts, corpus)?)?;
            }
            Section::Explain => emit_explain_human(stdout, &trace_identifier(iri, opts.hints))?,
        }
    }
    Ok(())
}

#[derive(Clone)]
struct UrlCount {
    url: String,
    count: usize,
    first: usize,
}

fn emit_url_list<W: Write>(stdout: &mut W, iris: &[Identifier], opts: &Opts) -> io::Result<()> {
    let mut counts: HashMap<String, UrlCount> = HashMap::new();
    let mut order: Vec<String> = Vec::new();
    for (i, iri) in iris.iter().enumerate() {
        let key = iri.canonical();
        if let Some(c) = counts.get_mut(&key) {
            c.count += 1;
        } else {
            counts.insert(
                key.clone(),
                UrlCount {
                    url: key.clone(),
                    count: 1,
                    first: i,
                },
            );
            order.push(key);
        }
    }
    let mut entries: Vec<UrlCount> = order.iter().map(|k| counts[k].clone()).collect();
    entries.sort_by(|a, b| {
        if a.count != b.count {
            b.count.cmp(&a.count)
        } else {
            a.first.cmp(&b.first)
        }
    });

    if opts.json {
        let arr: Vec<Value> = entries
            .iter()
            .map(|c| {
                let mut m = serde_json::Map::new();
                m.insert("iri".to_string(), Value::String(c.url.clone()));
                m.insert("count".to_string(), Value::Number((c.count as u64).into()));
                Value::Object(m)
            })
            .collect();
        emit_json_array(stdout, &arr, opts)?;
        return Ok(());
    }

    let all_unique = entries.iter().all(|c| c.count == 1);
    for c in &entries {
        if all_unique {
            writeln!(stdout, "{}", c.url)?;
        } else {
            writeln!(stdout, "[{}] {}", c.count, c.url)?;
        }
    }
    Ok(())
}

fn emit_clusters<W: Write>(stdout: &mut W, clusters: &[Cluster], opts: &Opts) -> io::Result<()> {
    let mut sorted: Vec<&Cluster> = clusters.iter().collect();
    sorted.sort_by_key(|c| std::cmp::Reverse(c.count));

    if opts.json {
        let arr: Vec<Value> = sorted.iter().map(|c| cluster_json(c)).collect();
        emit_json_array(stdout, &arr, opts)?;
        return Ok(());
    }

    for (i, c) in sorted.iter().enumerate() {
        if i > 0 {
            writeln!(stdout)?;
        }
        let host = if c.host.is_empty() {
            "(urn)"
        } else {
            c.host.as_str()
        };
        let shape = if opts.hints {
            c.shape.clone()
        } else {
            raw_shape_for(c)
        };
        writeln!(stdout, "[{}] {}  {}", c.count, host, shape)?;
        let limit = c.examples.len().min(3);
        for e in &c.examples[..limit] {
            writeln!(stdout, "    {}", e.canonical())?;
        }
        let remaining = c.count.saturating_sub(limit);
        if remaining > 0 {
            writeln!(stdout, "    + {} more", remaining)?;
        }
        emit_param_summary(stdout, c)?;
    }
    Ok(())
}

fn raw_shape_for(c: &Cluster) -> String {
    if let Some(ex) = c.examples.first() {
        iriq::path_shape_for(&ex.path_segments, false)
    } else {
        c.shape.clone()
    }
}

fn cluster_json(c: &Cluster) -> Value {
    let mut m = serde_json::Map::new();
    m.insert("key".to_string(), Value::String(c.key.clone()));
    m.insert("host".to_string(), Value::String(c.host.clone()));
    m.insert("scheme".to_string(), Value::String(c.scheme.clone()));
    m.insert("shape".to_string(), Value::String(c.shape.clone()));
    m.insert("count".to_string(), Value::Number((c.count as u64).into()));
    m.insert(
        "examples".to_string(),
        Value::Array(
            c.examples
                .iter()
                .map(|e| Value::String(e.canonical()))
                .collect(),
        ),
    );
    let stats = c.segment_stats();
    let segs: Vec<Value> = stats
        .iter()
        .map(|s| {
            let mut o = serde_json::Map::new();
            o.insert(
                "position".to_string(),
                Value::Number((s.position as u64).into()),
            );
            o.insert("stable".to_string(), Value::Bool(s.stable));
            let mut v = serde_json::Map::new();
            for (k, n) in &s.values {
                v.insert(k.clone(), Value::Number((*n as u64).into()));
            }
            o.insert("values".to_string(), Value::Object(v));
            Value::Object(o)
        })
        .collect();
    m.insert("segments".to_string(), Value::Array(segs));
    let summaries = c.param_summary();
    let params: Vec<Value> = summaries
        .iter()
        .map(|p| {
            let mut o = serde_json::Map::new();
            o.insert("name".to_string(), Value::String(p.name.clone()));
            o.insert("count".to_string(), Value::Number((p.count as u64).into()));
            o.insert("type".to_string(), Value::String(p.ty.as_str().to_string()));
            o.insert("confidence".to_string(), Value::from(p.confidence));
            o.insert(
                "cardinality".to_string(),
                Value::Number((p.cardinality as u64).into()),
            );
            o.insert("presence".to_string(), Value::from(p.presence));
            // Conditional fields mirror Ruby's Cluster#param_summary so the
            // cluster JSON is identical across runtimes.
            if !p.values.is_empty() {
                o.insert(
                    "values".to_string(),
                    Value::Array(p.values.iter().map(|v| Value::String(v.clone())).collect()),
                );
            }
            if !p.value_distribution.is_empty() {
                o.insert(
                    "value_distribution".to_string(),
                    float_map(p.value_distribution.iter().map(|(k, v)| (k.clone(), *v))),
                );
            }
            if !p.subtype_distribution.is_empty() {
                o.insert(
                    "subtype_distribution".to_string(),
                    float_map(
                        p.subtype_distribution
                            .iter()
                            .map(|(k, v)| (k.as_str().to_string(), *v)),
                    ),
                );
            }
            if !p.kind_distribution.is_empty() {
                o.insert(
                    "kind_distribution".to_string(),
                    float_map(
                        p.kind_distribution
                            .iter()
                            .map(|(k, v)| (k.as_str().to_string(), *v)),
                    ),
                );
            }
            if p.numeric_count > 0 {
                o.insert("min".to_string(), Value::from(p.min));
                o.insert("max".to_string(), Value::from(p.max));
                o.insert("avg".to_string(), Value::from(p.avg));
            }
            Value::Object(o)
        })
        .collect();
    m.insert("params".to_string(), Value::Array(params));
    Value::Object(m)
}

// Build a JSON object from string→f64 pairs.
fn float_map<I: IntoIterator<Item = (String, f64)>>(pairs: I) -> Value {
    let mut o = serde_json::Map::new();
    for (k, v) in pairs {
        o.insert(k, Value::from(v));
    }
    Value::Object(o)
}

fn emit_param_summary<W: Write>(stdout: &mut W, c: &Cluster) -> io::Result<()> {
    let rows = c.param_summary();
    if rows.is_empty() {
        return Ok(());
    }
    let width = rows.iter().map(|r| r.name.len()).max().unwrap_or(0);
    for r in rows {
        let mut parts = vec![r.ty.as_str().to_string()];
        if r.confidence > 0.0 {
            parts.push(format!("conf {:.2}", r.confidence));
        }
        if r.numeric_count > 0 {
            parts.push(format!("{}..{}", format_num(r.min), format_num(r.max)));
            parts.push(format!("avg {}", format_num(r.avg)));
        }
        parts.push(format!(
            "({} distinct, {}%)",
            r.cardinality,
            (r.presence * 100.0 + 0.5) as u32
        ));
        writeln!(
            stdout,
            "    {:<width$}  {}",
            r.name,
            parts.join("  "),
            width = width
        )?;
    }
    Ok(())
}

// Ruby's `format_num` (lib/iriq/cli.rb): a whole value prints as its exact
// integer (`Float#to_i`), anything else as `Float#round(2).to_s`.
fn format_num(n: f64) -> String {
    if n == n.trunc() {
        // `to_i` has no negative zero.
        return if n == 0.0 {
            "0".to_string()
        } else {
            format!("{n:.0}")
        };
    }
    ruby_float_to_s(ruby_round2(n))
}

// `Float#to_s` (flo_to_s in Ruby's numeric.c) for a `ruby_round2` result, which
// is zero or at least 0.01 in magnitude, so never Ruby's small-exponent form.
fn ruby_float_to_s(r: f64) -> String {
    if r != r.trunc() {
        // Both runtimes print the shortest round-tripping digits, but when the
        // value sits exactly between two candidates Ruby keeps the even last
        // digit and `{}` does not; exact formatting at that length matches Ruby.
        let shortest = r.to_string();
        let decimals = shortest.split_once('.').map_or(0, |(_, f)| f.len());
        return format!("{r:.decimals$}");
    }
    let int = format!("{:.0}", r.abs());
    if int.len() <= f64::DIGITS as usize {
        return format!("{r:.1}");
    }
    // Past DBL_DIG integer digits Ruby switches to `d.ddde+XX`.
    let digits = int.trim_end_matches('0');
    let (lead, rest) = digits.split_at(1);
    let rest = if rest.is_empty() { "0" } else { rest };
    let sign = if r < 0.0 { "-" } else { "" };
    format!("{sign}{lead}.{rest}e+{:02}", int.len() - 1)
}

// `Float#round(2)`: flo_round and round_half_up in Ruby's numeric.c.
fn ruby_round2(x: f64) -> f64 {
    const NDIGITS: i32 = 2;
    const FLOAT_DIG: i32 = f64::DIGITS as i32 + 2;
    const SCALE: f64 = 100.0;
    let binexp = frexp_exponent(x);
    // float_round_overflow: x * 100 is already an integer.
    let low_decimal_exp = if binexp > 0 {
        binexp / 4
    } else {
        binexp / 3 - 1
    };
    if NDIGITS >= FLOAT_DIG - low_decimal_exp {
        return x;
    }
    // float_round_underflow: too small to reach the second decimal.
    let high_decimal_exp = if binexp > 0 {
        binexp / 3 + 1
    } else {
        binexp / 4
    };
    if NDIGITS < -high_decimal_exp {
        return 0.0;
    }
    let mut f = (x * SCALE).round();
    // x * 100 can round below the half; this re-checks against x itself.
    if x > 0.0 {
        if (f + 0.5) / SCALE <= x {
            f += 1.0;
        }
    } else if (f - 0.5) / SCALE >= x {
        f -= 1.0;
    }
    f / SCALE
}

// The exponent C's frexp reports: x = m * 2^exp with 0.5 <= |m| < 1.
fn frexp_exponent(x: f64) -> i32 {
    if x == 0.0 {
        return 0;
    }
    let biased = ((x.to_bits() >> 52) & 0x7ff) as i32;
    if biased == 0 {
        // Subnormal: scale into the normal range first.
        frexp_exponent(x * 2f64.powi(54)) - 54
    } else {
        biased - 1022
    }
}

// ── Stats ───────────────────────────────────────────────────────────────────

fn cmd_stats<W: Write, E: Write>(
    stdout: &mut W,
    stderr: &mut E,
    corpus: Option<&Corpus>,
    opts: &Opts,
) -> Result<u8, Failure> {
    let Some(c) = corpus else {
        return Ok(emit_error(
            stderr,
            opts.json,
            "missing_argument",
            "missing argument <--corpus>",
            "",
            1,
        ));
    };
    emit_stats(stdout, c, opts)?;
    Ok(0)
}

fn emit_stats<W: Write>(stdout: &mut W, corpus: &Corpus, opts: &Opts) -> Result<(), Failure> {
    let hosts_full = corpus.host_counts()?;
    let observations: usize = hosts_full.values().copied().sum();
    let hosts = top_n_map(&hosts_full, TOP_N_STATS);
    let shapes_full = corpus.fingerprint_counts()?;
    let shapes = top_n_map(&shapes_full, TOP_N_STATS);
    let raw_full = corpus.raw_shape_counts()?;
    let raw = top_n_map(&raw_full, TOP_N_STATS);
    let clusters = corpus.size()?;

    if opts.json {
        let mut out = serde_json::Map::new();
        out.insert(
            "observations".to_string(),
            Value::Number((observations as u64).into()),
        );
        out.insert(
            "clusters".to_string(),
            Value::Number((clusters as u64).into()),
        );
        out.insert("hosts".to_string(), kv_to_value(&hosts));
        out.insert("shapes".to_string(), kv_to_value(&shapes));
        out.insert("raw_shapes".to_string(), kv_to_value(&raw));
        write_json(stdout, &Value::Object(out))?;
        return Ok(());
    }

    writeln!(stdout, "observations: {}", observations)?;
    writeln!(stdout, "clusters:     {}", clusters)?;
    writeln!(stdout)?;
    writeln!(stdout, "top hosts:")?;
    for (k, v) in &hosts {
        writeln!(stdout, "  {:>6}  {}", v, k)?;
    }
    writeln!(stdout)?;
    writeln!(stdout, "top shapes:")?;
    let shape_rows = if opts.hints { &shapes } else { &raw };
    for (k, v) in shape_rows {
        writeln!(stdout, "  {:>6}  {}", v, k)?;
    }
    Ok(())
}

fn top_n_map(m: &HashMap<String, usize>, n: usize) -> Vec<(String, usize)> {
    let mut v: Vec<(String, usize)> = m.iter().map(|(k, v)| (k.clone(), *v)).collect();
    v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    v.truncate(n);
    v
}

fn kv_to_value(pairs: &[(String, usize)]) -> Value {
    let mut o = serde_json::Map::new();
    for (k, v) in pairs {
        o.insert(k.clone(), Value::Number((*v as u64).into()));
    }
    Value::Object(o)
}

// ── Reinfer / Propose / Cross-host shapes ───────────────────────────────────

fn cmd_reinfer<W: Write, E: Write>(
    stdout: &mut W,
    stderr: &mut E,
    corpus: Option<&mut Corpus>,
    opts: &Opts,
) -> Result<u8, Failure> {
    let Some(c) = corpus else {
        return Ok(emit_error(
            stderr,
            opts.json,
            "missing_argument",
            "missing argument <--corpus>",
            "",
            1,
        ));
    };
    let n = c.observed_iri_count()?;
    let before = c.size()?;
    c.reinfer()?;
    let after = c.size()?;
    let noun = if n == 1 {
        "observation"
    } else {
        "observations"
    };
    let clusters = if after == 1 { "cluster" } else { "clusters" };
    writeln!(
        stdout,
        "reinferred {} {}: {} → {} {}",
        n, noun, before, after, clusters
    )?;
    Ok(0)
}

fn cmd_propose<W: Write, E: Write>(
    stdout: &mut W,
    stderr: &mut E,
    corpus: Option<&mut Corpus>,
    opts: &Opts,
) -> Result<u8, Failure> {
    let Some(c) = corpus else {
        return Ok(emit_error(
            stderr,
            opts.json,
            "missing_argument",
            "missing argument <--corpus>",
            "",
            1,
        ));
    };
    let mut popts = ProposalOptions::default();
    popts.min_observations = opts.propose_min_obs;
    popts.min_coverage = opts.propose_min_coverage;
    popts.min_hosts = opts.min_hosts;
    if opts.activate_above > 0.0 {
        let activated = c.activate_proposals_above(opts.activate_above, popts)?;
        if activated.is_empty() {
            writeln!(
                stdout,
                "no proposals at or above confidence {}",
                opts.activate_above
            )?;
            return Ok(0);
        }
        for r in activated {
            writeln!(stdout, "activated: {} ({})", r.suggested_type, r.prefix)?;
        }
        return Ok(0);
    }

    let proposals = c.propose_recognizers(popts)?;
    if opts.json {
        let arr: Vec<Value> = proposals.iter().map(proposal_json).collect();
        write_json(stdout, &Value::Array(arr))?;
        return Ok(0);
    }
    if proposals.is_empty() {
        writeln!(
            stdout,
            "no recognizer proposals ({} observations scanned)",
            c.observed_iri_count()?
        )?;
        return Ok(0);
    }
    for (i, p) in proposals.iter().enumerate() {
        if i > 0 {
            writeln!(stdout)?;
        }
        writeln!(stdout, "proposal: {} ({})", p.suggested_type, p.prefix)?;
        writeln!(stdout, "  strategy:    {}", p.strategy)?;
        writeln!(stdout, "  coverage:    {:.2}", p.coverage)?;
        writeln!(stdout, "  confidence:  {:.2}", p.confidence)?;
        writeln!(stdout, "  observations: {}", p.observation_count)?;
        writeln!(stdout, "  hosts:       {}", p.hosts.join(", "))?;
        writeln!(stdout, "  positions:   {}", p.positions.len())?;
        let samples = if p.sample_values.len() > 3 {
            &p.sample_values[..3]
        } else {
            &p.sample_values[..]
        };
        writeln!(stdout, "  samples:     {}", samples.join(", "))?;
    }
    Ok(0)
}

fn proposal_json(p: &RecognizerProposal) -> Value {
    let mut o = serde_json::Map::new();
    o.insert("prefix".to_string(), Value::String(p.prefix.clone()));
    o.insert(
        "suggested_type".to_string(),
        Value::String(p.suggested_type.clone()),
    );
    let pos: Vec<Value> = p
        .positions
        .iter()
        .map(|pos| {
            let mut o = serde_json::Map::new();
            o.insert("host".to_string(), Value::String(pos.host.clone()));
            o.insert(
                "scope".to_string(),
                Value::String(pos.scope.as_str().to_string()),
            );
            o.insert("locator".to_string(), Value::String(pos.locator.clone()));
            Value::Object(o)
        })
        .collect();
    o.insert("positions".to_string(), Value::Array(pos));
    o.insert(
        "hosts".to_string(),
        Value::Array(p.hosts.iter().map(|h| Value::String(h.clone())).collect()),
    );
    o.insert(
        "coverage".to_string(),
        Value::Number(serde_json::Number::from_f64(p.coverage).unwrap()),
    );
    o.insert(
        "confidence".to_string(),
        Value::Number(serde_json::Number::from_f64(p.confidence).unwrap()),
    );
    o.insert(
        "observation_count".to_string(),
        Value::Number((p.observation_count as u64).into()),
    );
    o.insert(
        "sample_values".to_string(),
        Value::Array(
            p.sample_values
                .iter()
                .map(|s| Value::String(s.clone()))
                .collect(),
        ),
    );
    o.insert("strategy".to_string(), Value::String(p.strategy.clone()));
    Value::Object(o)
}

fn cmd_cross_host_shapes<W: Write, E: Write>(
    stdout: &mut W,
    stderr: &mut E,
    corpus: Option<&Corpus>,
    opts: &Opts,
) -> Result<u8, Failure> {
    let Some(c) = corpus else {
        return Ok(emit_error(
            stderr,
            opts.json,
            "missing_argument",
            "missing argument <--corpus>",
            "",
            1,
        ));
    };
    let shapes = c.cross_host_shapes(opts.min_hosts)?;
    if opts.json {
        let arr: Vec<Value> = shapes
            .iter()
            .map(|s| {
                let mut o = serde_json::Map::new();
                o.insert("shape".to_string(), Value::String(s.shape.clone()));
                o.insert(
                    "hosts".to_string(),
                    Value::Array(s.hosts.iter().map(|h| Value::String(h.clone())).collect()),
                );
                o.insert(
                    "host_count".to_string(),
                    Value::Number((s.host_count() as u64).into()),
                );
                o.insert(
                    "observation_count".to_string(),
                    Value::Number((s.observation_count as u64).into()),
                );
                Value::Object(o)
            })
            .collect();
        write_json(stdout, &Value::Array(arr))?;
        return Ok(0);
    }
    if shapes.is_empty() {
        let size = c.size()?;
        let noun = if size == 1 { "cluster" } else { "clusters" };
        writeln!(stdout, "no cross-host shapes ({} {} scanned)", size, noun)?;
        return Ok(0);
    }
    for s in shapes {
        let noun = if s.host_count() == 1 { "host" } else { "hosts" };
        writeln!(
            stdout,
            "{}  ({} {}: {})  obs={}",
            s.shape,
            s.host_count(),
            noun,
            s.hosts.join(", "),
            s.observation_count
        )?;
    }
    Ok(0)
}

// ── Completion ──────────────────────────────────────────────────────────────

fn cmd_completion<W: Write, E: Write>(
    stdout: &mut W,
    stderr: &mut E,
    args: &[String],
    json_mode: bool,
) -> io::Result<u8> {
    let default_shell = default_shell();
    let shell = args.first().map(|s| s.as_str()).unwrap_or(&default_shell);
    match shell {
        "bash" => {
            write!(stdout, "{}", BASH_COMPLETION)?;
        }
        "zsh" => {
            write!(stdout, "{}", ZSH_COMPLETION)?;
        }
        _ => {
            return Ok(emit_error(
                stderr,
                json_mode,
                "unknown_shell",
                &format!("unknown shell {:?} (try bash or zsh)", shell),
                "",
                1,
            ));
        }
    }
    Ok(0)
}

// Mirrors the Ruby CLI: with no shell argument, infer from $SHELL
// (basename, `.exe` stripped), falling back to bash.
fn default_shell() -> String {
    let shell = std::env::var("SHELL").unwrap_or_default();
    if shell.is_empty() {
        return "bash".to_string();
    }
    let base = shell.rsplit(['/', '\\']).next().unwrap_or(&shell);
    base.strip_suffix(".exe").unwrap_or(base).to_string()
}

// Inlined copies of the shared completion scripts at completions/
// {iriq.bash,_iriq}. crates.io packages cannot reach files
// outside the crate root, so they are embedded here — keep them
// byte-identical to the gem copies (script/cli_parity.sh enforces it).
const BASH_COMPLETION: &str = r##"# Bash completion for the `iriq` CLI.
#
# Install (pick one):
#   - Persist via Homebrew: brew install dpep/tools/iriq automatically
#     drops this script into Homebrew's bash-completion dir.
#   - Try it out in the current shell:
#       source <(iriq completion bash)
#   - Persist to ~/.bashrc:
#       echo 'source <(iriq completion bash)' >> ~/.bashrc
#   - Or write to your system's bash completion dir:
#       iriq completion bash > /usr/local/etc/bash_completion.d/iriq

_iriq() {
    local cur prev words cword
    _init_completion 2>/dev/null || {
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
    }

    # Argument completion for flags that take a value.
    case "$prev" in
        --corpus)
            # Corpus paths are file-shaped. _filedir picks up *.json / *.db
            # / *.sqlite / *.sqlite3 by default extension; the user can also
            # tab through any path.
            _filedir
            return
            ;;
        --host)
            COMPREPLY=( $(compgen -W "full registrable reg none" -- "$cur") )
            return
            ;;
        --min-observations|--min-hosts|--min-coverage|--activate-above)
            # Numeric argument — no completion candidates.
            return
            ;;
        completion)
            COMPREPLY=( $(compgen -W "bash zsh" -- "$cur") )
            return
            ;;
    esac

    # If the current token starts with `-`, complete flags.
    if [[ "$cur" == -* ]]; then
        local flags="-h --help -V --version -p --parse -n --normalize -c --canonical -e --explain
                     -j --json -J --ndjson -N --no-hints --hints --no-scheme-less
                     --scheme-less --corpus -C --no-corpus --reset --host --stats --reinfer
                     --propose-recognizers --activate-above --cross-host-shapes
                     --min-observations --min-coverage --min-hosts"
        COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
        return
    fi

    # First non-flag positional may be a subcommand or a file/IRI.
    if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "cluster completion" -- "$cur") )
        # Also offer files for the auto-extract path (iriq ./access.log).
        local files
        files=$(compgen -f -- "$cur")
        if [[ -n "$files" ]]; then
            COMPREPLY+=( $files )
        fi
        return
    fi

    # Otherwise fall back to file completion (e.g. `iriq cluster <file>`).
    _filedir
}

complete -F _iriq iriq
"##;

const ZSH_COMPLETION: &str = r##"#compdef iriq
# Zsh completion for the `iriq` CLI.
#
# Install (pick one):
#   - Persist via Homebrew: brew install dpep/tools/iriq drops this file
#     into Homebrew's zsh site-functions dir automatically.
#   - Try in the current shell:
#       source <(iriq completion zsh)
#   - Or copy this file into a directory listed in $fpath and run
#     `compinit` (typically run by your zshrc).

_iriq() {
    local context state state_descr line
    typeset -A opt_args

    _arguments -C \
        '(-h --help)'{-h,--help}'[show usage]' \
        '(-V --version)'{-V,--version}'[print version]' \
        '(-p --parse)'{-p,--parse}'[parsed fields section]' \
        '(-n --normalize)'{-n,--normalize}'[normalized section]' \
        '(-c --canonical)'{-c,--canonical}'[canonical form section]' \
        '(-e --explain)'{-e,--explain}'[annotated trace section]' \
        '(-j --json)'{-j,--json}'[JSON output]' \
        '(-J --ndjson)'{-J,--ndjson}'[newline-delimited JSON]' \
        '(-N --no-hints)'{-N,--no-hints}'[use {type} placeholders, not {hint}]' \
        '--hints[enable hint placeholders]' \
        '--no-scheme-less[skip schemeless URL extraction]' \
        '--scheme-less[enable schemeless URL extraction]' \
        '--corpus[load/create a JSON or SQLite corpus]:corpus path:_files -g "*.(json|db|sqlite|sqlite3)"' \
        '(-C --no-corpus)'{-C,--no-corpus}'[disable corpus persistence for this invocation]' \
        '--reset[delete the corpus database and exit]' \
        '--host[host-keying strategy for clustering]:strategy:(full registrable reg none)' \
        '--stats[print rolling aggregates]' \
        '--reinfer[replay the source-IRI log]' \
        '--propose-recognizers[propose new Recognizers from observed shapes]' \
        '--cross-host-shapes[list route shapes seen across multiple hosts]' \
        '--activate-above[auto-activate proposals at or above this confidence]:F:' \
        '--min-observations[proposal threshold]:N:' \
        '--min-coverage[proposal threshold]:F:' \
        '--min-hosts[threshold for proposals and cross-host shapes]:N:' \
        '1:command or file:->first' \
        '*:file:_files' \
        && return 0

    case $state in
        first)
            _alternative \
                'commands:command:(cluster completion)' \
                'files:file:_files'
            ;;
    esac
}

_iriq "$@"
"##;

// ── JSON helpers ─────────────────────────────────────────────────────────────

fn write_json<W: Write>(stdout: &mut W, v: &Value) -> io::Result<()> {
    writeln!(stdout, "{}", serde_json::to_string(v).unwrap())?;
    Ok(())
}

fn emit_json_array<W: Write>(stdout: &mut W, arr: &[Value], opts: &Opts) -> io::Result<()> {
    if opts.ndjson {
        for v in arr {
            writeln!(stdout, "{}", serde_json::to_string(v).unwrap())?;
        }
    } else {
        write_json(stdout, &Value::Array(arr.to_vec()))?;
    }
    Ok(())
}

fn emit_error<W: Write>(
    stderr: &mut W,
    json_mode: bool,
    code: &str,
    message: &str,
    human: &str,
    exit: u8,
) -> u8 {
    if json_mode {
        let v = json!({"error": {"code": code, "message": message}});
        let _ = writeln!(stderr, "{}", serde_json::to_string(&v).unwrap());
    } else if !human.is_empty() {
        let _ = writeln!(stderr, "{}", human);
    } else {
        let _ = writeln!(stderr, "iriq: {}", message);
    }
    exit
}

#[cfg(test)]
mod tests {
    use super::{format_num, run};
    use std::io::{self, Write};

    struct FailingStdout(io::ErrorKind);

    impl Write for FailingStdout {
        fn write(&mut self, _: &[u8]) -> io::Result<usize> {
            Err(self.0.into())
        }
        fn flush(&mut self) -> io::Result<()> {
            Err(self.0.into())
        }
    }

    fn run_with_stdout_failing(kind: io::ErrorKind) -> (u8, String) {
        let argv = ["-C", "-n", "https://foo.com/users/1"].map(String::from);
        let mut stderr = Vec::new();
        let code = run(io::empty(), FailingStdout(kind), &mut stderr, &argv);
        (code, String::from_utf8(stderr).unwrap())
    }

    #[test]
    fn a_broken_pipe_exits_quietly_and_other_stdout_failures_are_errors() {
        assert_eq!(
            run_with_stdout_failing(io::ErrorKind::BrokenPipe),
            (141, String::new())
        );
        let (code, stderr) = run_with_stdout_failing(io::ErrorKind::StorageFull);
        assert_eq!(code, 1, "{stderr}");
        assert!(stderr.starts_with("iriq: stdout: "), "{stderr}");
    }

    #[test]
    fn format_num_matches_ruby() {
        // Each expectation is Ruby's `Iriq::CLI#format_num` output for the value.
        let cases: &[(f64, &str)] = &[
            (18446744073709551616.0, "18446744073709551616"),
            (1e23, "99999999999999991611392"),
            (6004799503160661.0, "6004799503160661"),
            (0.0, "0"),
            (-0.0, "0"),
            (3.5, "3.5"),
            (0.75, "0.75"),
            (4.998, "5.0"),
            (0.001, "0.0"),
            (-0.004, "-0.0"),
            (-0.00001, "0.0"),
            (1.005, "1.01"),
            (2.675, "2.68"),
            (-0.125, "-0.13"),
            (1234.565, "1234.57"),
            (4503599627370495.5, "4503599627370495.5"),
            // Exactly between the two shortest candidates, .12 and .13.
            (92_132_193_871_992.0 + 0.125, "92132193871992.12"),
            (2983624634074204.5, "2.983624634074205e+15"),
            (-4123968251008709.5, "-4.12396825100871e+15"),
        ];
        for &(n, want) in cases {
            assert_eq!(format_num(n), want, "format_num({n:e})");
        }
    }
}
