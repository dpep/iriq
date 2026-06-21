// Rust port of the iriq CLI. Phase 2 scope: corpus persistence (JSON +
// SQLite), --stats, --reinfer, --propose-recognizers, --cross-host-shapes,
// --activate-above, --host, completion. Phase 1 (-n/-c/-p/-e, -j/-J,
// pipe-mode URL list, cluster auto-switch) also covered here.

use iriq::{
    classifier::DEFAULT_CLASSIFIER, cross_host_shape::cross_host_shapes, normalize_identifier,
    parse, trace_identifier, Cluster, Corpus, Extractor, HostStrategy, Identifier, ParseError,
    ProposalOptions, RecognizerProposal, TraceResult,
};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::process::ExitCode;

const LARGE_BATCH_THRESHOLD: usize = 10;
const TOP_N_STATS: usize = 10;

const USAGE: &str = r#"iriq — find a URL's shape: the route template behind it (e.g. /users/{id}).

Usage: iriq [options] <input>
       iriq [options] < text
       iriq cluster [options] [file]

Sections (combine freely):
  -n, --normalize       Shape — variable parts become placeholders
  -c, --canonical       Clean form — tidy scheme/host, keep the values
  -p, --parse           Parsed fields
  -e, --explain         Annotated trace — per-segment notes about why
                        each placeholder / canonical value was chosen

Corpus + stats:
      --corpus PATH     Load/create a JSON / SQLite corpus; observe + save.
                        .db/.sqlite/.sqlite3 → SQLite (incremental UPSERTs).
      --host MODE       Host-keying strategy: full (default), reg / registrable
                        strips subdomains, none ignores host entirely.
      --stats           Print rolling aggregates
      --reinfer         Replay the source-IRI log through current classifier
                        + reducers; rebuilds materialized views.
      --propose-recognizers
                        Scan observed values for shape patterns that recur
                        enough to suggest a new Recognizer.
      --cross-host-shapes
                        List route shapes that recur across multiple hosts.
      --activate-above F With --propose-recognizers, promote every proposal
                        at or above CONFIDENCE F into a live Recognizer.

Other:
  -h, --help            Show this message
  -j, --json            Emit JSON instead of human-readable output
  -J, --ndjson          Newline-delimited JSON (one object per line). Implies --json.
  -N, --no-hints        Use {integer} placeholders instead of {user_id}
      --no-scheme-less  Skip foo.com/path extraction (explicit-scheme only)
  -V, --version         Print version

Subcommands:
  cluster [file]        Force cluster view (default for >=10 IRIs anyway)
  completion <shell>    Print shell completion script (bash | zsh | fish)
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
        let _ = write!(stdout, "{}", USAGE);
        return 0;
    }
    if opts.version {
        let _ = writeln!(stdout, "{}", iriq::VERSION);
        return 0;
    }

    // `completion <shell>` short-circuits.
    if args.first().map(|s| s.as_str()) == Some("completion") {
        return cmd_completion(&mut stdout, &mut stderr, &args[1..], opts.json);
    }

    let mut args = args;
    let mut explicit_cluster = false;
    if args.first().map(|s| s.as_str()) == Some("cluster") {
        explicit_cluster = true;
        args.remove(0);
    }

    let positional_is_file = match args.first() {
        Some(arg) => {
            if let Ok(meta) = std::fs::metadata(arg) {
                meta.is_file() && !parseable_iri(arg)
            } else {
                false
            }
        }
        None => false,
    };

    let piped = !atty_isatty_stdin();
    let batch_mode = explicit_cluster || positional_is_file || (args.is_empty() && piped);

    if args.is_empty() && !batch_mode && !opts.reinfer && !opts.propose && !opts.cross_host_shapes {
        let _ = write!(stdout, "{}", USAGE);
        return 0;
    }

    let mut corpus: Option<Corpus> = None;
    if !opts.corpus.is_empty() {
        match Corpus::open(&opts.corpus) {
            Ok(mut c) => {
                c.set_host_strategy(opts.host_strategy);
                corpus = Some(c);
            }
            Err(e) => {
                let _ = writeln!(stderr, "iriq: {}", e);
                return 1;
            }
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

    if let Some(mut c) = corpus {
        if !opts.corpus.is_empty() {
            if let Err(e) = c.save(&opts.corpus) {
                let _ = writeln!(stderr, "iriq: {}", e);
                return 1;
            }
        }
        let _ = c.close();
    }
    code
}

fn atty_isatty_stdin() -> bool {
    use std::os::fd::AsRawFd;
    extern "C" {
        fn isatty(fd: i32) -> i32;
    }
    // SAFETY: isatty is FFI; we pass a valid fd we got via AsRawFd.
    unsafe { isatty(io::stdin().as_raw_fd()) != 0 }
}

fn parseable_iri(s: &str) -> bool {
    parse(s).is_ok()
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
                    "--host" => opts.host_strategy = parse_host_strategy(val)?,
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
                opts.host_strategy =
                    parse_host_strategy(argv.get(i).ok_or("--host requires a value")?.as_str())?;
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

fn parse_host_strategy(v: &str) -> Result<HostStrategy, String> {
    match v.to_lowercase().as_str() {
        "full" => Ok(HostStrategy::Full),
        "registrable" | "reg" => Ok(HostStrategy::Registrable),
        "none" => Ok(HostStrategy::None),
        _ => Err(format!(
            "--host: expected full|registrable|reg|none, got {:?}",
            v
        )),
    }
}

// ── Summary mode ────────────────────────────────────────────────────────────

fn cmd_summary<W: Write, E: Write>(
    stdout: &mut W,
    stderr: &mut E,
    args: &[String],
    opts: &Opts,
    corpus: Option<&mut Corpus>,
) -> u8 {
    if args.is_empty() {
        return emit_error(
            stderr,
            opts.json,
            "missing_argument",
            "missing argument <input>",
            "",
            1,
        );
    }
    let iri = match parse(&args[0]) {
        Ok(i) => i,
        Err(ParseError(msg)) => {
            return emit_error(
                stderr,
                opts.json,
                "parse_error",
                &msg,
                &format!("iriq: parse error: {}", msg),
                2,
            );
        }
    };
    // Observe the input, then keep an immutable handle so the Normalize
    // section can use corpus-informed normalization — the whole point of
    // passing --corpus.
    let corpus: Option<&Corpus> = match corpus {
        Some(c) => {
            c.observe_iri(&iri);
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
            let payload = section_payload(&iri, sections[0], opts, corpus);
            write_json(stdout, &payload);
        } else {
            // Multi-section JSON: fixed key order parse / canonical / normalize / explain.
            let mut payload = serde_json::Map::new();
            for s in ["parse", "canonical", "normalize", "explain"] {
                if let Some(sec) = sections.iter().find(|sec| sec.name() == s) {
                    payload.insert(s.to_string(), section_payload(&iri, *sec, opts, corpus));
                }
            }
            write_json(stdout, &Value::Object(payload));
        }
        return 0;
    }

    emit_sections_human(stdout, &iri, &sections, opts, corpus);
    0
}

// Corpus-informed when a corpus is loaded; mechanical otherwise. This is what
// makes `iriq -n --corpus c.db` reflect observed distributions (e.g. a
// high-cardinality literal slot collapsing to a placeholder).
fn normalize_section(iri: &Identifier, opts: &Opts, corpus: Option<&Corpus>) -> String {
    match corpus {
        Some(c) => c.normalize_identifier(iri),
        None => normalize_identifier(iri, &DEFAULT_CLASSIFIER, opts.hints),
    }
}

fn section_payload(iri: &Identifier, sec: Section, opts: &Opts, corpus: Option<&Corpus>) -> Value {
    match sec {
        Section::Parse => identifier_json(iri),
        Section::Canonical => Value::String(iri.canonical()),
        Section::Normalize => Value::String(normalize_section(iri, opts, corpus)),
        Section::Explain => {
            serde_json::to_value(trace_identifier(iri, &DEFAULT_CLASSIFIER, opts.hints)).unwrap()
        }
    }
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
    if iri.port != 0 {
        o.insert("port".to_string(), Value::Number((iri.port as u64).into()));
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
        for (k, v) in iri.query_params.iter() {
            qp.insert(k.to_string(), Value::String(v.to_string()));
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
) {
    let multi = sections.len() > 1;
    for (i, sec) in sections.iter().enumerate() {
        if i > 0 {
            let _ = writeln!(stdout);
        }
        if multi {
            let _ = writeln!(stdout, "# {}", sec.name());
        }
        match sec {
            Section::Parse => emit_parse_human(stdout, iri),
            Section::Canonical => {
                let _ = writeln!(stdout, "{}", iri.canonical());
            }
            Section::Normalize => {
                let _ = writeln!(stdout, "{}", normalize_section(iri, opts, corpus));
            }
            Section::Explain => {
                emit_explain_human(
                    stdout,
                    &trace_identifier(iri, &DEFAULT_CLASSIFIER, opts.hints),
                );
            }
        }
    }
}

fn emit_parse_human<W: Write>(stdout: &mut W, iri: &Identifier) {
    let _ = writeln!(stdout, "original:      {}", iri.original);
    let _ = writeln!(stdout, "kind:          {}", iri.kind.as_str());
    if !iri.scheme.is_empty() {
        let _ = writeln!(stdout, "scheme:        {}", iri.scheme);
    }
    if !iri.host.is_empty() {
        let _ = writeln!(stdout, "host:          {}", iri.host);
    }
    if iri.port != 0 {
        let _ = writeln!(stdout, "port:          {}", iri.port);
    }
    if !iri.path_segments.is_empty() {
        let _ = writeln!(
            stdout,
            "path_segments: {}",
            inspect_strings(&iri.path_segments)
        );
    }
    if !iri.query_params.is_empty() {
        let mut keys = iri.query_params.keys();
        keys.sort();
        let m: HashMap<String, String> = keys
            .into_iter()
            .map(|k| {
                (
                    k.clone(),
                    iri.query_params.get(&k).unwrap_or("").to_string(),
                )
            })
            .collect();
        let _ = writeln!(stdout, "query_params:  {}", inspect_string_map_ordered(&m));
    }
    if !iri.fragment.is_empty() {
        let _ = writeln!(stdout, "fragment:      {}", iri.fragment);
    }
    if !iri.nss.is_empty() {
        let _ = writeln!(stdout, "nss:           {}", iri.nss);
    }
    let _ = writeln!(stdout, "canonical:     {}", iri.canonical());
}

fn inspect_strings(ss: &[String]) -> String {
    if ss.is_empty() {
        return "[]".to_string();
    }
    let parts: Vec<String> = ss.iter().map(|s| format!("{:?}", s)).collect();
    format!("[{}]", parts.join(", "))
}

fn inspect_string_map_ordered(m: &HashMap<String, String>) -> String {
    let mut keys: Vec<&String> = m.keys().collect();
    keys.sort();
    let parts: Vec<String> = keys
        .iter()
        .map(|k| format!("{:?}=>{:?}", k, m.get(*k).unwrap()))
        .collect();
    format!("{{{}}}", parts.join(", "))
}

fn emit_explain_human<W: Write>(stdout: &mut W, tr: &TraceResult) {
    let _ = writeln!(stdout, "{}", tr.normalized);
    emit_trace_section(stdout, "path", &tr.path);
    if !tr.query.is_empty() {
        emit_trace_section(stdout, "query", &tr.query);
    }
}

fn emit_trace_section<W: Write>(stdout: &mut W, label: &str, rows: &[iriq::TraceRow]) {
    if rows.is_empty() {
        return;
    }
    let _ = writeln!(stdout);
    let _ = writeln!(stdout, "{}:", label);
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
        let _ = writeln!(
            stdout,
            "  {:<nw$}  {:<tw$}  {:<ow$}{}",
            row_label(r),
            r.ty.as_str(),
            r.output,
            notes,
            nw = nw,
            tw = tw,
            ow = ow,
        );
    }
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
) -> u8 {
    let text = match read_text(stdin, args) {
        Ok(t) => t,
        Err(e) => {
            let _ = writeln!(stderr, "iriq: {}", e);
            return 1;
        }
    };
    let extractor = Extractor {
        scheme_less: opts.scheme_less,
    };
    let iris = extractor.extract(&text);

    // Feed observations into the corpus when present.
    let mut owned_corpus = if corpus.is_none() {
        Some(Corpus::new())
    } else {
        None
    };
    let working: &mut Corpus = match (corpus, &mut owned_corpus) {
        (Some(c), _) => c,
        (None, Some(c)) => c,
        _ => unreachable!(),
    };
    let _ = working.batch(|c| {
        for iri in &iris {
            c.observe_iri(iri);
        }
    });

    if !opts.sections.is_empty() {
        // Corpus-informed only when the user actually passed --corpus; the
        // throwaway in-memory corpus above is just for cluster/stats views.
        let real_corpus: Option<&Corpus> = if opts.corpus.is_empty() {
            None
        } else {
            Some(&*working)
        };
        emit_per_iri_sections(stdout, &iris, opts, real_corpus);
        return 0;
    }
    if opts.stats {
        emit_stats(stdout, working, opts);
        return 0;
    }
    if explicit_cluster || iris.len() >= LARGE_BATCH_THRESHOLD {
        emit_clusters(stdout, &working.clusters(), opts);
        return 0;
    }
    emit_url_list(stdout, &iris, opts);
    0
}

fn read_text<R: Read>(stdin: &mut R, args: &[String]) -> std::io::Result<String> {
    if args.is_empty() || args[0] == "-" {
        let mut s = String::new();
        stdin.read_to_string(&mut s)?;
        return Ok(s);
    }
    std::fs::read_to_string(&args[0])
}

fn emit_per_iri_sections<W: Write>(
    stdout: &mut W,
    iris: &[Identifier],
    opts: &Opts,
    corpus: Option<&Corpus>,
) {
    if opts.json {
        let mut payloads: Vec<Value> = Vec::with_capacity(iris.len());
        for iri in iris {
            if opts.sections.len() == 1 {
                payloads.push(section_payload(iri, opts.sections[0], opts, corpus));
            } else {
                let mut m = serde_json::Map::new();
                for s in ["parse", "canonical", "normalize", "explain"] {
                    if let Some(sec) = opts.sections.iter().find(|sec| sec.name() == s) {
                        m.insert(s.to_string(), section_payload(iri, *sec, opts, corpus));
                    }
                }
                payloads.push(Value::Object(m));
            }
        }
        emit_json_array(stdout, &payloads, opts);
        return;
    }

    if opts.sections.len() == 1
        && (opts.sections[0] == Section::Normalize || opts.sections[0] == Section::Canonical)
    {
        for iri in iris {
            match opts.sections[0] {
                Section::Canonical => {
                    let _ = writeln!(stdout, "{}", iri.canonical());
                }
                Section::Normalize => {
                    let _ = writeln!(stdout, "{}", normalize_section(iri, opts, corpus));
                }
                _ => {}
            }
        }
        return;
    }

    for (i, iri) in iris.iter().enumerate() {
        if i > 0 {
            let _ = writeln!(stdout);
        }
        let _ = writeln!(stdout, "# {}", iri.canonical());
        for (j, sec) in opts.sections.iter().enumerate() {
            if j > 0 {
                let _ = writeln!(stdout);
            }
            match sec {
                Section::Parse => emit_parse_human(stdout, iri),
                Section::Canonical => {
                    let _ = writeln!(stdout, "{}", iri.canonical());
                }
                Section::Normalize => {
                    let _ = writeln!(stdout, "{}", normalize_section(iri, opts, corpus));
                }
                Section::Explain => emit_explain_human(
                    stdout,
                    &trace_identifier(iri, &DEFAULT_CLASSIFIER, opts.hints),
                ),
            }
        }
    }
}

#[derive(Clone)]
struct UrlCount {
    url: String,
    count: usize,
    first: usize,
}

fn emit_url_list<W: Write>(stdout: &mut W, iris: &[Identifier], opts: &Opts) {
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
        emit_json_array(stdout, &arr, opts);
        return;
    }

    let all_unique = entries.iter().all(|c| c.count == 1);
    for c in &entries {
        if all_unique {
            let _ = writeln!(stdout, "{}", c.url);
        } else {
            let _ = writeln!(stdout, "[{}] {}", c.count, c.url);
        }
    }
}

fn emit_clusters<W: Write>(stdout: &mut W, clusters: &[Cluster], opts: &Opts) {
    let mut sorted: Vec<&Cluster> = clusters.iter().collect();
    sorted.sort_by_key(|c| std::cmp::Reverse(c.count));

    if opts.json {
        let arr: Vec<Value> = sorted.iter().map(|c| cluster_json(c)).collect();
        emit_json_array(stdout, &arr, opts);
        return;
    }

    for (i, c) in sorted.iter().enumerate() {
        if i > 0 {
            let _ = writeln!(stdout);
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
        let _ = writeln!(stdout, "[{}] {}  {}", c.count, host, shape);
        let limit = c.examples.len().min(3);
        for e in &c.examples[..limit] {
            let _ = writeln!(stdout, "    {}", e.canonical());
        }
        let remaining = c.count.saturating_sub(limit);
        if remaining > 0 {
            let _ = writeln!(stdout, "    + {} more", remaining);
        }
        emit_param_summary(stdout, c);
    }
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
            o.insert(
                "cardinality".to_string(),
                Value::Number((p.cardinality as u64).into()),
            );
            o.insert("presence".to_string(), Value::from(p.presence));
            Value::Object(o)
        })
        .collect();
    m.insert("params".to_string(), Value::Array(params));
    Value::Object(m)
}

fn emit_param_summary<W: Write>(stdout: &mut W, c: &Cluster) {
    let rows = c.param_summary();
    if rows.is_empty() {
        return;
    }
    let width = rows.iter().map(|r| r.name.len()).max().unwrap_or(0);
    for r in rows {
        let mut parts = vec![r.ty.as_str().to_string()];
        if r.numeric_count > 0 {
            parts.push(format!("{}..{}", format_num(r.min), format_num(r.max)));
            parts.push(format!("avg {}", format_num(r.avg)));
        }
        parts.push(format!(
            "({} distinct, {}%)",
            r.cardinality,
            (r.presence * 100.0 + 0.5) as u32
        ));
        let _ = writeln!(
            stdout,
            "    {:<width$}  {}",
            r.name,
            parts.join("  "),
            width = width
        );
    }
}

fn format_num(n: f64) -> String {
    if n == n.trunc() {
        format!("{}", n as i64)
    } else {
        let rounded = (n * 100.0).round() / 100.0;
        format!("{}", rounded)
    }
}

// ── Stats ───────────────────────────────────────────────────────────────────

fn cmd_stats<W: Write, E: Write>(
    stdout: &mut W,
    stderr: &mut E,
    corpus: Option<&Corpus>,
    opts: &Opts,
) -> u8 {
    let Some(c) = corpus else {
        return emit_error(
            stderr,
            opts.json,
            "missing_argument",
            "missing argument <--corpus>",
            "",
            1,
        );
    };
    emit_stats(stdout, c, opts);
    0
}

fn emit_stats<W: Write>(stdout: &mut W, corpus: &Corpus, opts: &Opts) {
    let hosts_full = corpus.host_counts();
    let observations: usize = hosts_full.values().copied().sum();
    let hosts = top_n_map(&hosts_full, TOP_N_STATS);
    let shapes_full = corpus.fingerprint_counts();
    let shapes = top_n_map(&shapes_full, TOP_N_STATS);
    let raw_full = corpus.raw_shape_counts();
    let raw = top_n_map(&raw_full, TOP_N_STATS);

    if opts.json {
        let mut out = serde_json::Map::new();
        out.insert(
            "observations".to_string(),
            Value::Number((observations as u64).into()),
        );
        out.insert(
            "clusters".to_string(),
            Value::Number((corpus.size() as u64).into()),
        );
        out.insert("hosts".to_string(), kv_to_value(&hosts));
        out.insert("shapes".to_string(), kv_to_value(&shapes));
        out.insert("raw_shapes".to_string(), kv_to_value(&raw));
        write_json(stdout, &Value::Object(out));
        return;
    }

    let _ = writeln!(stdout, "observations: {}", observations);
    let _ = writeln!(stdout, "clusters:     {}", corpus.size());
    let _ = writeln!(stdout);
    let _ = writeln!(stdout, "top hosts:");
    for (k, v) in &hosts {
        let _ = writeln!(stdout, "  {:>6}  {}", v, k);
    }
    let _ = writeln!(stdout);
    let _ = writeln!(stdout, "top shapes:");
    let shape_rows = if opts.hints { &shapes } else { &raw };
    for (k, v) in shape_rows {
        let _ = writeln!(stdout, "  {:>6}  {}", v, k);
    }
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
) -> u8 {
    let Some(c) = corpus else {
        return emit_error(
            stderr,
            opts.json,
            "missing_argument",
            "missing argument <--corpus>",
            "",
            1,
        );
    };
    let n = c.observed_iri_count();
    let before = c.size();
    if let Err(e) = c.reinfer() {
        let _ = writeln!(stderr, "iriq: {}", e);
        return 1;
    }
    let after = c.size();
    let noun = if n == 1 {
        "observation"
    } else {
        "observations"
    };
    let clusters = if after == 1 { "cluster" } else { "clusters" };
    let _ = writeln!(
        stdout,
        "reinferred {} {}: {} → {} {}",
        n, noun, before, after, clusters
    );
    0
}

fn cmd_propose<W: Write, E: Write>(
    stdout: &mut W,
    stderr: &mut E,
    corpus: Option<&mut Corpus>,
    opts: &Opts,
) -> u8 {
    let Some(c) = corpus else {
        return emit_error(
            stderr,
            opts.json,
            "missing_argument",
            "missing argument <--corpus>",
            "",
            1,
        );
    };
    let popts = ProposalOptions {
        min_observations: opts.propose_min_obs,
        min_coverage: opts.propose_min_coverage,
        min_hosts: opts.min_hosts,
    };
    if opts.activate_above > 0.0 {
        match c.activate_proposals_above(opts.activate_above, popts) {
            Ok(activated) => {
                if activated.is_empty() {
                    let _ = writeln!(
                        stdout,
                        "no proposals at or above coverage {}",
                        opts.activate_above
                    );
                    return 0;
                }
                for r in activated {
                    let _ = writeln!(stdout, "activated: {} ({})", r.ty.as_str(), r.prefix);
                }
                return 0;
            }
            Err(e) => {
                let _ = writeln!(stderr, "iriq: {}", e);
                return 1;
            }
        }
    }

    let proposals = c.propose_recognizers(popts);
    if opts.json {
        let arr: Vec<Value> = proposals.iter().map(proposal_json).collect();
        write_json(stdout, &Value::Array(arr));
        return 0;
    }
    if proposals.is_empty() {
        let _ = writeln!(
            stdout,
            "no recognizer proposals ({} observations scanned)",
            c.observed_iri_count()
        );
        return 0;
    }
    for (i, p) in proposals.iter().enumerate() {
        if i > 0 {
            let _ = writeln!(stdout);
        }
        let _ = writeln!(stdout, "proposal: {} ({})", p.suggested_type, p.prefix);
        let _ = writeln!(stdout, "  strategy:    {}", p.strategy);
        let _ = writeln!(stdout, "  coverage:    {:.2}", p.coverage);
        let _ = writeln!(stdout, "  confidence:  {:.2}", p.confidence);
        let _ = writeln!(stdout, "  observations: {}", p.observation_count);
        let _ = writeln!(stdout, "  hosts:       {}", p.hosts.join(", "));
        let _ = writeln!(stdout, "  positions:   {}", p.positions.len());
        let samples = if p.sample_values.len() > 3 {
            &p.sample_values[..3]
        } else {
            &p.sample_values[..]
        };
        let _ = writeln!(stdout, "  samples:     {}", samples.join(", "));
    }
    0
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
) -> u8 {
    let Some(c) = corpus else {
        return emit_error(
            stderr,
            opts.json,
            "missing_argument",
            "missing argument <--corpus>",
            "",
            1,
        );
    };
    let shapes = cross_host_shapes(c, opts.min_hosts);
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
        write_json(stdout, &Value::Array(arr));
        return 0;
    }
    if shapes.is_empty() {
        let size = c.size();
        let noun = if size == 1 { "cluster" } else { "clusters" };
        let _ = writeln!(stdout, "no cross-host shapes ({} {} scanned)", size, noun);
        return 0;
    }
    for s in shapes {
        let noun = if s.host_count() == 1 { "host" } else { "hosts" };
        let _ = writeln!(
            stdout,
            "{}  ({} {}: {})  obs={}",
            s.shape,
            s.host_count(),
            noun,
            s.hosts.join(", "),
            s.observation_count
        );
    }
    0
}

// ── Completion ──────────────────────────────────────────────────────────────

fn cmd_completion<W: Write, E: Write>(
    stdout: &mut W,
    stderr: &mut E,
    args: &[String],
    json_mode: bool,
) -> u8 {
    let shell = match args.first() {
        Some(s) => s.as_str(),
        None => {
            return emit_error(
                stderr,
                json_mode,
                "missing_argument",
                "missing shell argument; expected bash | zsh | fish",
                "iriq: completion: missing shell argument; expected bash | zsh | fish",
                1,
            );
        }
    };
    match shell {
        "bash" => {
            let _ = write!(stdout, "{}", BASH_COMPLETION);
        }
        "zsh" => {
            let _ = write!(stdout, "{}", ZSH_COMPLETION);
        }
        "fish" => {
            let _ = write!(stdout, "{}", FISH_COMPLETION);
        }
        _ => {
            return emit_error(
                stderr,
                json_mode,
                "invalid_argument",
                &format!("unknown shell {:?}; expected bash | zsh | fish", shell),
                &format!(
                    "iriq: completion: unknown shell {:?}; expected bash | zsh | fish",
                    shell
                ),
                1,
            );
        }
    }
    0
}

const BASH_COMPLETION: &str = r#"# iriq bash completion (rust port)
_iriq() {
  COMPREPLY=( $(compgen -W "-n -c -p -e -j -J -N -V -h --normalize --canonical --parse --explain --json --ndjson --no-hints --version --help --corpus --host --stats --reinfer --propose-recognizers --cross-host-shapes --activate-above --min-hosts --min-observations --min-coverage --no-scheme-less cluster completion" -- "${COMP_WORDS[COMP_CWORD]}") )
}
complete -F _iriq iriq
"#;

const ZSH_COMPLETION: &str = r#"# iriq zsh completion (rust port)
_iriq() {
  local -a opts
  opts=('-n' '-c' '-p' '-e' '-j' '-J' '-N' '-V' '-h' '--normalize' '--canonical' '--parse' '--explain' '--json' '--ndjson' '--no-hints' '--version' '--help' '--corpus' '--host' '--stats' '--reinfer' '--propose-recognizers' '--cross-host-shapes' '--activate-above' '--min-hosts' '--min-observations' '--min-coverage' '--no-scheme-less' 'cluster' 'completion')
  compadd "${opts[@]}"
}
compdef _iriq iriq
"#;

const FISH_COMPLETION: &str = r#"# iriq fish completion (rust port)
complete -c iriq -s n -l normalize
complete -c iriq -s c -l canonical
complete -c iriq -s p -l parse
complete -c iriq -s e -l explain
complete -c iriq -s j -l json
complete -c iriq -s J -l ndjson
complete -c iriq -s N -l no-hints
complete -c iriq -s V -l version
complete -c iriq -s h -l help
complete -c iriq -l corpus -r
complete -c iriq -l host -r
complete -c iriq -l stats
complete -c iriq -l reinfer
complete -c iriq -l propose-recognizers
complete -c iriq -l cross-host-shapes
complete -c iriq -l activate-above -r
complete -c iriq -l min-hosts -r
complete -c iriq -l min-observations -r
complete -c iriq -l min-coverage -r
complete -c iriq -l no-scheme-less
complete -c iriq -n '__fish_use_subcommand' -a cluster
complete -c iriq -n '__fish_use_subcommand' -a completion
"#;

// ── JSON helpers ─────────────────────────────────────────────────────────────

fn write_json<W: Write>(stdout: &mut W, v: &Value) {
    let _ = writeln!(stdout, "{}", serde_json::to_string(v).unwrap());
}

fn emit_json_array<W: Write>(stdout: &mut W, arr: &[Value], opts: &Opts) {
    if opts.ndjson {
        for v in arr {
            let _ = writeln!(stdout, "{}", serde_json::to_string(v).unwrap());
        }
    } else {
        write_json(stdout, &Value::Array(arr.to_vec()));
    }
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
