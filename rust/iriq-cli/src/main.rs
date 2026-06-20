// Rust port of the iriq CLI. Phase 1 scope: -n/-c/-p/-e and -j/-J,
// pipe-mode URL list, cluster auto-switch, --no-hints, --no-scheme-less.
// Skips: --corpus persistence, --stats, --reinfer, --propose-recognizers,
// --cross-host-shapes, completion. Those land in phase 2.

use iriq::{
    classifier::DEFAULT_CLASSIFIER, normalize_identifier, parse, trace_identifier, Extractor,
    Identifier, ParseError, TraceResult,
};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::process::ExitCode;

const LARGE_BATCH_THRESHOLD: usize = 10;
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

Other:
  -h, --help            Show this message
  -j, --json            Emit JSON instead of human-readable output
  -J, --ndjson          Newline-delimited JSON (one object per line). Implies --json.
  -N, --no-hints        Use {integer} placeholders instead of {user_id}
      --no-scheme-less  Skip foo.com/path extraction (explicit-scheme only)
  -V, --version         Print version

Subcommands:
  cluster [file]        Force cluster view (default for >=10 IRIs anyway)
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
}

fn default_opts() -> Opts {
    Opts {
        hints: true,
        scheme_less: true,
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
            return emit_error(&mut stderr, argv_wants_json(argv), "option_error", &e, "", 1);
        }
    };
    if opts.help {
        let _ = write!(stdout, "{}", USAGE);
        let _ = writeln!(stdout, "\nBuild: rust port (json corpus only)");
        return 0;
    }
    if opts.version {
        let _ = writeln!(stdout, "{}", iriq::VERSION);
        return 0;
    }

    // Detect explicit `cluster` subcommand
    let mut args = args;
    let mut explicit_cluster = false;
    if args.first().map(|s| s.as_str()) == Some("cluster") {
        explicit_cluster = true;
        args.remove(0);
    }

    // Auto file-detect on positional argument
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

    let piped = !atty_isatty_stdin_fallback();
    let batch_mode = explicit_cluster || positional_is_file || (args.is_empty() && piped);

    if args.is_empty() && !batch_mode {
        let _ = write!(stdout, "{}", USAGE);
        return 0;
    }

    if batch_mode {
        cmd_batch(&mut stdin, &mut stdout, &mut stderr, &args, &opts, explicit_cluster)
    } else {
        cmd_summary(&mut stdout, &mut stderr, &args, &opts)
    }
}

fn atty_isatty_stdin_fallback() -> bool {
    // Without the `atty` crate, fall back to treating stdin as piped when
    // we're not running in a terminal. We use a tiny FFI-free approximation:
    // when STDIN is redirected, Linux exposes /proc/self/fd/0 as a non-tty
    // file. Easiest: query metadata.
    use std::os::fd::AsRawFd;
    let fd = io::stdin().as_raw_fd();
    unsafe { libc_isatty(fd) != 0 }
}

extern "C" {
    fn isatty(fd: i32) -> i32;
}

#[allow(non_snake_case)]
fn libc_isatty(fd: i32) -> i32 {
    unsafe { isatty(fd) }
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
            s if s.starts_with("--") => {
                return Err(format!("invalid option: {}", s));
            }
            s if s.starts_with('-') && s.len() > 1 => {
                // Combined short flags like -pn or -nN
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

// ── Summary: single IRI input ───────────────────────────────────────────────

fn cmd_summary<W: Write, E: Write>(
    stdout: &mut W,
    stderr: &mut E,
    args: &[String],
    opts: &Opts,
) -> u8 {
    if args.is_empty() {
        return emit_error(stderr, opts.json, "missing_argument", "missing argument <input>", "", 1);
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

    let sections = if opts.sections.is_empty() {
        vec![Section::Parse, Section::Normalize]
    } else {
        opts.sections.clone()
    };

    if opts.json {
        if sections.len() == 1 {
            let payload = section_payload(&iri, sections[0], opts);
            write_json(stdout, &payload);
        } else {
            let mut payload = serde_json::Map::new();
            for s in &sections {
                payload.insert(s.name().to_string(), section_payload(&iri, *s, opts));
            }
            write_json(stdout, &Value::Object(payload));
        }
        return 0;
    }

    emit_sections_human(stdout, &iri, &sections, opts);
    0
}

fn section_payload(iri: &Identifier, sec: Section, opts: &Opts) -> Value {
    match sec {
        Section::Parse => identifier_json(iri),
        Section::Canonical => Value::String(iri.canonical()),
        Section::Normalize => {
            Value::String(normalize_identifier(iri, &DEFAULT_CLASSIFIER, opts.hints))
        }
        Section::Explain => trace_json(&trace_identifier(iri, &DEFAULT_CLASSIFIER, opts.hints)),
    }
}

fn identifier_json(iri: &Identifier) -> Value {
    let mut o = serde_json::Map::new();
    o.insert("original".to_string(), Value::String(iri.original.clone()));
    o.insert("kind".to_string(), Value::String(iri.kind.as_str().to_string()));
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
            Value::Array(iri.path_segments.iter().map(|s| Value::String(s.clone())).collect()),
        );
    }
    if iri.query_params.len() > 0 {
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

fn trace_json(tr: &TraceResult) -> Value {
    serde_json::to_value(tr).unwrap()
}

// ── Human renderers ─────────────────────────────────────────────────────────

fn emit_sections_human<W: Write>(
    stdout: &mut W,
    iri: &Identifier,
    sections: &[Section],
    opts: &Opts,
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
                let _ = writeln!(
                    stdout,
                    "{}",
                    normalize_identifier(iri, &DEFAULT_CLASSIFIER, opts.hints)
                );
            }
            Section::Explain => {
                emit_explain_human(stdout, &trace_identifier(iri, &DEFAULT_CLASSIFIER, opts.hints));
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
        let _ = writeln!(stdout, "path_segments: {}", inspect_strings(&iri.path_segments));
    }
    if iri.query_params.len() > 0 {
        let mut keys = iri.query_params.keys();
        keys.sort();
        let m: HashMap<String, String> = keys
            .into_iter()
            .map(|k| (k.clone(), iri.query_params.get(&k).unwrap_or("").to_string()))
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
    explicit_cluster: bool,
) -> u8 {
    let text = match read_text(stdin, args) {
        Ok(t) => t,
        Err(e) => {
            let _ = writeln!(stderr, "iriq: {}", e);
            return 1;
        }
    };
    let extractor = Extractor { scheme_less: opts.scheme_less };
    let iris = extractor.extract(&text);

    if !opts.sections.is_empty() {
        emit_per_iri_sections(stdout, &iris, opts);
        return 0;
    }
    if explicit_cluster || iris.len() >= LARGE_BATCH_THRESHOLD {
        emit_clusters(stdout, &iris, opts);
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

fn emit_per_iri_sections<W: Write>(stdout: &mut W, iris: &[Identifier], opts: &Opts) {
    if opts.json {
        let mut payloads: Vec<Value> = Vec::with_capacity(iris.len());
        for iri in iris {
            if opts.sections.len() == 1 {
                payloads.push(section_payload(iri, opts.sections[0], opts));
            } else {
                let mut m = serde_json::Map::new();
                for s in &opts.sections {
                    m.insert(s.name().to_string(), section_payload(iri, *s, opts));
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
                    let _ = writeln!(
                        stdout,
                        "{}",
                        normalize_identifier(iri, &DEFAULT_CLASSIFIER, opts.hints)
                    );
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
                    let _ = writeln!(
                        stdout,
                        "{}",
                        normalize_identifier(iri, &DEFAULT_CLASSIFIER, opts.hints)
                    );
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
            counts.insert(key.clone(), UrlCount { url: key.clone(), count: 1, first: i });
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

// ── Clustering (in-process only, no persistent corpus) ──────────────────────

struct ClusterAcc {
    host: String,
    scheme: String,
    shape: String,
    count: usize,
    examples: Vec<Identifier>,
    seen_examples: std::collections::HashSet<String>,
    param_stats: HashMap<String, ParamStats>,
}

#[derive(Default)]
struct ParamStats {
    count: usize,
    type_counts: HashMap<String, usize>,
    value_counts: HashMap<String, usize>,
    numeric_count: usize,
    numeric_min: f64,
    numeric_max: f64,
    numeric_sum: f64,
}

const MAX_EXAMPLES: usize = 10;

fn emit_clusters<W: Write>(stdout: &mut W, iris: &[Identifier], opts: &Opts) {
    use iriq::path_shape::PathShape;

    // Build clusters keyed on host + raw shape (mechanical, hints-on form).
    let mut clusters: indexmap_lite::Map<String, ClusterAcc> = indexmap_lite::Map::new();
    let mut ps = PathShape::new();
    ps.hints = true;
    ps.canonical_dates = true;
    ps.canonical_currencies = true;
    for iri in iris {
        let host = iri.host.clone();
        let shape = ps.for_segments(&iri.path_segments);
        let key = format!("{}|{}", host, shape);
        let entry = clusters.entry(key).or_insert_with(|| ClusterAcc {
            host: host.clone(),
            scheme: iri.scheme.clone(),
            shape: shape.clone(),
            count: 0,
            examples: Vec::new(),
            seen_examples: std::collections::HashSet::new(),
            param_stats: HashMap::new(),
        });
        entry.count += 1;
        if entry.examples.len() < MAX_EXAMPLES {
            let canon = iri.canonical();
            if entry.seen_examples.insert(canon) {
                entry.examples.push(iri.clone());
            }
        }
        for (k, v) in iri.query_params.iter() {
            let stats = entry.param_stats.entry(k.to_string()).or_default();
            stats.count += 1;
            let t = DEFAULT_CLASSIFIER.classify(v).as_str().to_string();
            *stats.type_counts.entry(t.clone()).or_insert(0) += 1;
            *stats.value_counts.entry(v.to_string()).or_insert(0) += 1;
            if let Ok(n) = v.parse::<f64>() {
                if stats.numeric_count == 0 {
                    stats.numeric_min = n;
                    stats.numeric_max = n;
                } else {
                    if n < stats.numeric_min {
                        stats.numeric_min = n;
                    }
                    if n > stats.numeric_max {
                        stats.numeric_max = n;
                    }
                }
                stats.numeric_sum += n;
                stats.numeric_count += 1;
            }
        }
    }

    let mut sorted: Vec<&ClusterAcc> = clusters.values().collect();
    sorted.sort_by(|a, b| b.count.cmp(&a.count));

    if opts.json {
        let arr: Vec<Value> = sorted
            .iter()
            .map(|c| {
                let mut m = serde_json::Map::new();
                m.insert("key".to_string(), Value::String(format!("{}://{}{}", c.scheme, c.host, c.shape)));
                m.insert("host".to_string(), Value::String(c.host.clone()));
                m.insert("scheme".to_string(), Value::String(c.scheme.clone()));
                m.insert("shape".to_string(), Value::String(c.shape.clone()));
                m.insert("count".to_string(), Value::Number((c.count as u64).into()));
                m.insert(
                    "examples".to_string(),
                    Value::Array(c.examples.iter().map(|e| Value::String(e.canonical())).collect()),
                );
                Value::Object(m)
            })
            .collect();
        emit_json_array(stdout, &arr, opts);
        return;
    }

    for (i, c) in sorted.iter().enumerate() {
        if i > 0 {
            let _ = writeln!(stdout);
        }
        let host = if c.host.is_empty() { "(urn)" } else { c.host.as_str() };
        let _ = writeln!(stdout, "[{}] {}  {}", c.count, host, c.shape);
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

fn emit_param_summary<W: Write>(stdout: &mut W, c: &ClusterAcc) {
    if c.param_stats.is_empty() {
        return;
    }
    let mut names: Vec<&String> = c.param_stats.keys().collect();
    names.sort_by(|a, b| {
        let ca = c.param_stats[*a].count;
        let cb = c.param_stats[*b].count;
        cb.cmp(&ca).then(a.cmp(b))
    });
    let width = names.iter().map(|n| n.len()).max().unwrap_or(0);
    for name in names {
        let st = &c.param_stats[name];
        let ty = dominant_type_for(st);
        let presence = (st.count as f64) / (c.count as f64);
        let cardinality = st.value_counts.len();
        let mut parts = vec![ty.clone()];
        if st.numeric_count > 0 {
            parts.push(format!("{}..{}", format_num(st.numeric_min), format_num(st.numeric_max)));
            parts.push(format!("avg {}", format_num(st.numeric_sum / st.numeric_count as f64)));
        }
        parts.push(format!(
            "({} distinct, {}%)",
            cardinality,
            (presence * 100.0 + 0.5) as u32
        ));
        let _ = writeln!(
            stdout,
            "    {:<width$}  {}",
            name,
            parts.join("  "),
            width = width
        );
    }
}

fn dominant_type_for(st: &ParamStats) -> String {
    // Promote :enum when value-counts are bounded; same heuristic as Go.
    const ENUM_MIN_OBSERVATIONS: usize = 20;
    const ENUM_MAX_CARDINALITY: usize = 10;
    const ENUM_MIN_VALUE_COUNT: usize = 2;
    const ENUM_MIN_COVERAGE: f64 = 0.95;
    if st.count >= ENUM_MIN_OBSERVATIONS && st.value_counts.len() <= ENUM_MAX_CARDINALITY {
        let covered: usize = st.value_counts.values().copied().sum();
        let all_repeat = st.value_counts.values().all(|&n| n >= ENUM_MIN_VALUE_COUNT);
        if all_repeat && (covered as f64) / (st.count as f64) >= ENUM_MIN_COVERAGE {
            // Boolean wins over enum when the dominant type is :boolean.
            if dominant(&st.type_counts) != "boolean" {
                return "enum".to_string();
            }
        }
    }
    dominant(&st.type_counts)
}

fn dominant(m: &HashMap<String, usize>) -> String {
    let mut best: Option<(&String, usize)> = None;
    for (k, v) in m {
        best = match best {
            None => Some((k, *v)),
            Some((bk, bv)) => {
                if *v > bv || (*v == bv && k.as_str() < bk.as_str()) {
                    Some((k, *v))
                } else {
                    Some((bk, bv))
                }
            }
        };
    }
    best.map(|(k, _)| k.clone()).unwrap_or_else(|| "literal".to_string())
}

fn format_num(n: f64) -> String {
    if n == n.trunc() {
        format!("{}", n as i64)
    } else {
        let rounded = (n * 100.0).round() / 100.0;
        // strip trailing zeros
        let s = format!("{}", rounded);
        s
    }
}

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
        let v = json!({"error": code, "message": message});
        let _ = writeln!(stderr, "{}", serde_json::to_string(&v).unwrap());
    } else if !human.is_empty() {
        let _ = writeln!(stderr, "{}", human);
    } else {
        let _ = writeln!(stderr, "iriq: {}", message);
    }
    exit
}

// Tiny insertion-order map without pulling in indexmap.
mod indexmap_lite {
    use std::collections::HashMap;

    pub struct Map<K, V> {
        order: Vec<K>,
        inner: HashMap<K, V>,
    }

    impl<K: std::hash::Hash + Eq + Clone, V> Map<K, V> {
        pub fn new() -> Self {
            Self { order: Vec::new(), inner: HashMap::new() }
        }
        pub fn entry(&mut self, k: K) -> Entry<'_, K, V> {
            if !self.inner.contains_key(&k) {
                self.order.push(k.clone());
            }
            Entry { map: self, k }
        }
        pub fn values(&self) -> impl Iterator<Item = &V> {
            self.order.iter().map(move |k| self.inner.get(k).unwrap())
        }
    }

    pub struct Entry<'a, K: std::hash::Hash + Eq + Clone, V> {
        map: &'a mut Map<K, V>,
        k: K,
    }

    impl<'a, K: std::hash::Hash + Eq + Clone, V> Entry<'a, K, V> {
        pub fn or_insert_with<F: FnOnce() -> V>(self, f: F) -> &'a mut V {
            self.map.inner.entry(self.k).or_insert_with(f)
        }
    }
}
