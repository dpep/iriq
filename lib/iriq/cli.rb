require "json"
require "optparse"
require "stringio"

module Iriq
  # Flag-driven CLI. The default action for an input is a combined parse +
  # normalize + explain summary; the -p/-n/-e flags select individual
  # sections. The only subcommand is `cluster`, which is structurally
  # different (many inputs, not one). Construct with explicit IO so specs
  # can run it without shelling out.
  class CLI
    SECTION_FLAGS = %i[parse normalize].freeze
    TOP_N_STATS   = 10

    # When extraction yields this many or more IRIs, the default pipe
    # output switches from a URL list to clusters — a longer list is
    # easier to read as route-shape groups.
    LARGE_BATCH_THRESHOLD = 10

    USAGE = <<~TXT
      iriq — find a URL's shape: the route template behind it (e.g. /users/{id}).

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
            --corpus PATH     Load/create a JSON corpus; observe and save atomically.
                              -n becomes corpus-informed once it has data.
            --host MODE       Host-keying strategy for clustering:
                              full (default), registrable (or reg) strips
                              subdomains, none ignores host entirely.
            --stats           Print rolling aggregates
            --reinfer         Replay the source-IRI log through the current
                              classifier + reducers; rebuilds materialized
                              views from scratch. Requires --corpus.
            --propose-recognizers
                              Scan observed values for shape patterns that
                              recur enough to suggest a new Recognizer.
                              Combine with --json for structured output.
                              Requires --corpus.
            --cross-host-shapes
                              List route shapes that recur across
                              multiple hosts. Combine with --min-hosts.
                              Requires --corpus.
            --activate-above F  With --propose-recognizers, promote every
                              proposal at or above CONFIDENCE F into a
                              live Recognizer on the corpus, then
                              reinfer. Confidence integrates coverage
                              and cross-host corroboration.

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

      Examples:
        iriq foo.com/users/456
        iriq -n https://foo.com/users/123
        iriq ./access.log                     # auto-detect file → extract URLs
        cat README.md | iriq -n               # one normalized URL per line
        cat README.md | iriq --corpus c.json
    TXT

    attr_reader :stdin, :stdout, :stderr

    def initialize(stdin: $stdin, stdout: $stdout, stderr: $stderr)
      @stdin  = stdin
      @stdout = stdout
      @stderr = stderr
    end

    # Returns an integer exit code.
    def run(argv)
      # Pre-scan so an error during option parsing can still honor --json.
      # Re-set authoritatively from opts once parsing succeeds.
      @json = json_requested?(argv)
      args, opts = parse_options(argv)
      @json = opts[:json]

      return print_usage(stdout, 0) if opts[:help]
      return print_version          if opts[:version]

      # `iriq completion <shell>` short-circuits — no corpus, no IRI input,
      # just emit the script bundled with the gem.
      if args.first == "completion"
        args.shift
        return cmd_completion(args)
      end

      explicit_cluster = (args.first == "cluster")
      args.shift if explicit_cluster

      # Auto-detect: a positional argument that isn't parseable as an IRI
      # but IS an existing file gets treated as a file to extract from. This
      # is what makes `iriq ./access.log` and `iriq /var/log/foo.log` Just
      # Work without a separate --extract flag.
      positional_is_file = args.first && File.file?(args.first) && !parseable_iri?(args.first)

      batch_mode = explicit_cluster || positional_is_file ||
                   (args.empty? && piped_stdin?)

      return print_usage(stdout, 0) if args.empty? && !batch_mode && !opts[:reinfer] && !opts[:propose] && !opts[:cross_host_shapes]

      corpus = opts[:corpus] ? load_corpus(opts[:corpus], host_strategy: opts[:host_strategy]) : nil

      code = if opts[:reinfer]
        cmd_reinfer(corpus, opts)
      elsif opts[:propose]
        cmd_propose(corpus, opts)
      elsif opts[:cross_host_shapes]
        cmd_cross_host_shapes(corpus, opts)
      elsif batch_mode
        cmd_batch(args, opts, corpus, explicit_cluster: explicit_cluster)
      elsif opts[:stats]
        cmd_stats(corpus, opts)
      else
        cmd_summary(args, opts, corpus)
      end

      corpus.save(opts[:corpus]) if corpus && opts[:corpus]
      code
    rescue Iriq::ParseError => e
      emit_error("parse_error", e.message, 2, human: "iriq: parse error: #{e.message}")
    rescue OptionParser::ParseError => e
      emit_error("option_error", e.message, 1)
    end

    def parseable_iri?(input)
      Iriq.parse(input)
      true
    rescue Iriq::ParseError
      false
    end

    private

    def parse_options(argv)
      opts = {
        json:        false,
        ndjson:      false,
        help:        false,
        version:     false,
        hints:       true,
        sections:    [],
        corpus:        nil,
        stats:         false,
        reinfer:       false,
        propose:       false,
        propose_min_obs:      nil,
        propose_min_coverage: nil,
        # --min-hosts is generic: it applies to both --propose-recognizers
        # (proposal threshold) and --cross-host-shapes (cross-host
        # recurrence threshold).
        min_hosts:            nil,
        activate_above:       nil,
        cross_host_shapes:    false,
        scheme_less:   true,
        host_strategy: :full,
      }
      parser = OptionParser.new do |o|
        o.on("-p", "--parse")        { opts[:sections] << :parse }
        o.on("-n", "--normalize")    { opts[:sections] << :normalize }
        o.on("-c", "--canonical")    { opts[:sections] << :canonical }
        o.on("-e", "--explain")      { opts[:sections] << :explain }
        o.on("-j", "--json")         { opts[:json]    = true }
        o.on("-J", "--ndjson")       { opts[:json]    = true; opts[:ndjson] = true }
        o.on("--[no-]hints")         { |v| opts[:hints] = v }
        o.on("-N")                   { opts[:hints] = false }
        o.on("--corpus PATH")        { |v| opts[:corpus] = v }
        o.on("--host MODE")          { |v| opts[:host_strategy] = host_strategy_arg(v) }
        o.on("--stats")              { opts[:stats]   = true }
        o.on("--reinfer")            { opts[:reinfer] = true }
        o.on("--propose-recognizers") { opts[:propose] = true }
        o.on("--min-observations N", Integer) { |v| opts[:propose_min_obs]      = v }
        o.on("--min-coverage F", Float)       { |v| opts[:propose_min_coverage] = v }
        o.on("--min-hosts N", Integer)        { |v| opts[:min_hosts]           = v }
        o.on("--activate-above F", Float)     { |v| opts[:activate_above]       = v }
        o.on("--cross-host-shapes")           { opts[:cross_host_shapes]        = true }
        o.on("--[no-]scheme-less")   { |v| opts[:scheme_less] = v }
        o.on("-h", "--help")         { opts[:help]    = true }
        o.on("-V", "--version")      { opts[:version] = true }
      end
      args = parser.parse(argv)
      [args, opts]
    end

    def piped_stdin?
      # StringIO is the test injection point; treat it as "piped" only when
      # it actually has content. Real stdin: tty? tells us.
      if stdin.is_a?(StringIO)
        stdin.size.positive?
      elsif stdin.respond_to?(:tty?)
        !stdin.tty?
      else
        true
      end
    end

    def load_corpus(path, host_strategy: :full)
      Corpus.open(path, host_strategy: host_strategy)
    end

    # Accept `--host=reg` as a short alias for the `registrable` mode.
    HOST_STRATEGY_ALIASES = {
      "full" => :full, "registrable" => :registrable, "reg" => :registrable, "none" => :none,
    }.freeze

    def host_strategy_arg(value)
      mode = HOST_STRATEGY_ALIASES[value.to_s.downcase]
      raise OptionParser::InvalidArgument, "--host: expected full|registrable|reg|none, got #{value.inspect}" unless mode

      mode
    end

    def print_usage(io, code)
      io.puts USAGE
      code
    end

    def print_version
      stdout.puts Iriq::VERSION
      0
    end

    def cmd_summary(args, opts, corpus)
      input    = args.first or return missing(:input)
      iri      = Iriq.parse(input)
      corpus&.observe(iri)
      sections = opts[:sections].empty? ? SECTION_FLAGS : opts[:sections]

      data = {}
      data[:parse]     = identifier_hash(iri) if sections.include?(:parse)
      data[:canonical] = iri.canonical         if sections.include?(:canonical)
      if sections.include?(:normalize)
        data[:normalize] = corpus ? corpus.normalize(iri) : Normalizer.normalize_identifier(iri, hints: opts[:hints])
      end
      if sections.include?(:explain)
        data[:explain] = Trace.for(iri, hints: opts[:hints])
      end

      if opts[:json]
        payload = sections.size == 1 ? data.values.first : data
        stdout.puts JSON.generate(payload)
      else
        emit_sections(data, sections)
      end
      0
    end

    # Used for the `cluster` subcommand and implicit piped batch mode. Reads
    # the whole input as text and runs it through the extractor — so a file
    # of URLs (one per line) and a file of prose with URLs both work. The
    # corpus is ephemeral unless --corpus was given.
    def cmd_batch(args, opts, corpus, explicit_cluster: false)
      corpus ||= Corpus.new

      # Per-IRI sections (-n/-p/-c/-e) are independent line to line, so we
      # stream: read input lazily, extract per line, and emit each IRI as it
      # arrives (flushed for live `tail -f | iriq -n` pipelines). The aggregate
      # views below — stats, clusters, the deduped URL list — need the whole
      # input, so they slurp.
      if opts[:sections].any?
        emit_per_iri_sections(lazy_iris(args.first, opts), opts, corpus)
        return 0
      end

      iris = extract_text(read_text(args.first), opts)
      corpus.batch { iris.each { |iri| corpus.observe(iri) } }

      if opts[:stats]
        emit_stats(corpus, opts)
      elsif explicit_cluster || iris.size >= LARGE_BATCH_THRESHOLD
        # Either the user asked for clusters explicitly, or the input is
        # big enough that the cluster summary beats a long URL list.
        emit_clusters(corpus.clusters, opts)
      else
        emit_url_list(iris, opts)
      end
      0
    end

    # Lazily yield IRIs from the input, one input line at a time, so an
    # unbounded stream flows through without being buffered in full. Matches
    # whole-text extraction exactly: a candidate never spans a newline
    # (URL_CHAR_CLASS excludes whitespace) and `extract` does not dedup.
    def lazy_iris(path, opts)
      extractor = Extractor.new(scheme_less: opts[:scheme_less])
      input_lines(path).lazy.flat_map { |line| extractor.extract(line) }
    end

    def input_lines(path)
      if path.nil? || path == "-"
        stdin.each_line
      else
        File.foreach(path)
      end
    end

    # Emit the requested sections (parse/normalize/explain) for each extracted
    # IRI, observing each into `corpus` as it passes. `iris` may be a lazy
    # enumerator; human and NDJSON output stream (flushed per IRI) while a single
    # JSON array must be materialized. -n alone is the cleanest case: one line
    # per URL.
    def emit_per_iri_sections(iris, opts, corpus)
      sections = opts[:sections]

      # A wrapping JSON array can't be emitted incrementally — collect it
      # (force the lazy enumerator to a real Array so emit_json sees an array).
      if opts[:json] && !opts[:ndjson]
        payloads = iris.map { |iri| corpus.observe(iri); section_payload(iri, sections, opts) }.to_a
        out = sections.size == 1 ? payloads.map(&:values).flatten(1) : payloads
        return emit_json(out, opts)
      end

      iris.each_with_index do |iri, i|
        corpus.observe(iri)
        p = section_payload(iri, sections, opts)
        if opts[:ndjson]
          items = sections.size == 1 ? p.values : [p]
          items.each { |item| stdout.puts JSON.generate(item) }
        elsif sections == [:normalize] || sections == [:canonical]
          # Most common case — keep it tight: one URL per line, no headers.
          stdout.puts p[sections.first]
        else
          stdout.puts if i > 0
          stdout.puts "# #{iri.canonical}"
          sections.each_with_index do |sec, j|
            stdout.puts if j > 0  # blank line between sections within one IRI
            case sec
            when :parse     then emit_parse_human(p[:parse])
            when :canonical then stdout.puts p[:canonical]
            when :normalize then stdout.puts p[:normalize]
            end
          end
        end
        stdout.flush
      end
    end

    def section_payload(iri, sections, opts)
      data = {}
      data[:parse]     = identifier_hash(iri)                                       if sections.include?(:parse)
      data[:canonical] = iri.canonical                                              if sections.include?(:canonical)
      data[:normalize] = Normalizer.normalize_identifier(iri, hints: opts[:hints])  if sections.include?(:normalize)
      data
    end

    def extract_text(text, opts)
      Extractor.new(scheme_less: opts[:scheme_less]).extract(text)
    end

    # Emit a deduplicated list of IRIs with occurrence counts, sorted desc
    # by count then by first-seen order. If every IRI is a singleton the
    # `[1]` prefix is omitted — just print the URLs.
    def emit_url_list(iris, opts)
      counts = Hash.new(0)
      first  = {}
      iris.each_with_index do |iri, i|
        key = iri.canonical
        counts[key] += 1
        first[key] ||= i
      end

      sorted = counts.sort_by { |k, c| [-c, first[k]] }

      if opts[:json]
        emit_json(sorted.map { |k, c| { iri: k, count: c } }, opts)
      elsif sorted.all? { |_, c| c == 1 }
        sorted.each { |k, _| stdout.puts k }
      else
        sorted.each { |k, c| stdout.puts "[#{c}] #{k}" }
      end
    end

    def cmd_stats(corpus, opts)
      return missing("--corpus") unless corpus

      emit_stats(corpus, opts)
      0
    end

    # --propose-recognizers: scan observed values for prefix patterns
    # that recur enough to suggest a new Recognizer. Prints one block
    # per proposal in human mode, or a JSON array under --json. With
    # --activate-above F, every proposal at or above coverage F is
    # promoted to a live Recognizer on the corpus's classifier and the
    # corpus reinfers to apply the new classifier to existing
    # observations.
    def cmd_propose(corpus, opts)
      return missing("--corpus") unless corpus

      kwargs = {}
      kwargs[:min_observations] = opts[:propose_min_obs]      if opts[:propose_min_obs]
      kwargs[:min_coverage]     = opts[:propose_min_coverage] if opts[:propose_min_coverage]
      kwargs[:min_hosts]        = opts[:min_hosts]            if opts[:min_hosts]

      if opts[:activate_above]
        activated = corpus.activate_proposals_above(opts[:activate_above], **kwargs)
        if activated.empty?
          stdout.puts "no proposals at or above coverage #{opts[:activate_above]}"
        else
          activated.each do |r|
            stdout.puts "activated: #{r.type} (#{r.prefix})"
          end
        end
        return 0
      end

      proposals = corpus.propose_recognizers(**kwargs)

      if opts[:json]
        stdout.puts JSON.generate(proposals.map(&:to_h))
        return 0
      end

      if proposals.empty?
        stdout.puts "no recognizer proposals (#{corpus.observed_iri_count} observations scanned)"
        return 0
      end

      proposals.each_with_index do |p, i|
        stdout.puts if i > 0
        stdout.puts "proposal: #{p.suggested_type} (#{p.prefix})"
        stdout.puts "  strategy:    #{p.strategy}"
        stdout.puts "  coverage:    #{format('%.2f', p.coverage)}"
        stdout.puts "  confidence:  #{format('%.2f', p.confidence)}"
        stdout.puts "  observations: #{p.observation_count}"
        stdout.puts "  hosts:       #{p.hosts.to_a.sort.join(', ')}"
        stdout.puts "  positions:   #{p.positions.size}"
        stdout.puts "  samples:     #{p.sample_values.first(3).join(', ')}"
      end
      0
    end

    # --reinfer: drop the materialized views in the corpus and replay the
    # source-IRI log through the current classifier + reducers. Prints a
    # short before/after summary so the user can see what changed.
    def cmd_reinfer(corpus, _opts)
      return missing("--corpus") unless corpus

      n      = corpus.observed_iri_count
      before = corpus.size
      corpus.reinfer
      after  = corpus.size

      stdout.puts "reinferred #{n} observation#{n == 1 ? '' : 's'}: " \
                  "#{before} → #{after} cluster#{after == 1 ? '' : 's'}"
      0
    end

    # `completion <shell>` — emit the bundled shell-completion script.
    # Scripts live in completions/{iriq.bash,_iriq} alongside the gem;
    # Homebrew installs them automatically, but the user can also do
    # `source <(iriq completion bash)` in their shell rc.
    COMPLETIONS_DIR = File.expand_path("../../completions", __dir__).freeze
    COMPLETION_FILES = {
      "bash" => File.join(COMPLETIONS_DIR, "iriq.bash"),
      "zsh"  => File.join(COMPLETIONS_DIR, "_iriq"),
    }.freeze

    def cmd_completion(args)
      shell = args.first || default_shell
      path  = COMPLETION_FILES[shell]
      unless path
        return emit_error("unknown_shell", "unknown shell #{shell.inspect} (try bash or zsh)", 1)
      end
      stdout.write(File.read(path))
      0
    end

    def default_shell
      shell = ENV["SHELL"].to_s
      shell.empty? ? "bash" : File.basename(shell).sub(/\.exe\z/, "")
    end

    # --cross-host-shapes: list route shapes that recur across multiple
    # hosts in the corpus. One block per shape in human mode, JSON array
    # under --json. Tunable via --min-hosts (default 2).
    def cmd_cross_host_shapes(corpus, opts)
      return missing("--corpus") unless corpus

      kwargs = {}
      kwargs[:min_hosts] = opts[:min_hosts] if opts[:min_hosts]
      shapes = corpus.cross_host_shapes(**kwargs)

      if opts[:json]
        stdout.puts JSON.generate(shapes.map(&:to_h))
        return 0
      end

      if shapes.empty?
        stdout.puts "no cross-host shapes (#{corpus.size} cluster#{corpus.size == 1 ? '' : 's'} scanned)"
        return 0
      end

      shapes.each do |s|
        host_list = s.hosts.to_a.sort.join(", ")
        stdout.puts "#{s.shape}  (#{s.host_count} host#{s.host_count == 1 ? '' : 's'}: #{host_list})  obs=#{s.observation_count}"
      end
      0
    end

    def missing(name)
      emit_error("missing_argument", "missing argument <#{name}>", 1)
    end

    # Detect whether JSON output was requested by scanning raw argv. Used
    # before option parsing completes (or when it fails) so errors can still
    # honor --json. Handles bundled short flags like -nj.
    def json_requested?(argv)
      argv.any? do |a|
        a == "--json" || a == "--ndjson" ||
          (a.start_with?("-") && !a.start_with?("--") && a.match?(/[jJ]/))
      end
    end

    # Emit an error to stderr and return its exit code. Under --json/--ndjson
    # the error is a structured envelope ({"error":{"code","message"}}) so
    # agents and pipelines get parseable output on the failure path; otherwise
    # the plain "iriq: <human>" line (human defaults to "iriq: <message>").
    def emit_error(code, message, exit_code, human: nil)
      if @json
        stderr.puts JSON.generate(error: { code: code, message: message })
      else
        stderr.puts(human || "iriq: #{message}")
      end
      exit_code
    end

    def read_input(path)
      if path.nil? || path == "-"
        stdin.read.lines
      else
        File.readlines(path)
      end
    end

    def read_text(path)
      if path.nil? || path == "-"
        stdin.read
      else
        File.read(path)
      end
    end

    # Compact identifier hash for parse output (both JSON and human). Drops
    # nil values and empty collections so URN dumps don't carry empty
    # host/path/query slots, and URL dumps don't include null fragment/nss.
    def identifier_hash(iri)
      {
        original:      iri.original,
        kind:          iri.kind,
        scheme:        iri.scheme,
        host:          iri.host,
        port:          iri.port,
        path_segments: iri.path_segments,
        query_params:  iri.query_params,
        fragment:      iri.fragment,
        nss:           iri.nss,
        canonical:     iri.canonical,
      }.reject { |_, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
    end

    # Emit a JSON payload to stdout. When --ndjson is set and the payload is
    # an Array, write one object per line (newline-delimited JSON) instead of
    # one wrapping array — friendlier for `jq -c`, streaming pipelines, and
    # log ingest tools. Non-array payloads (single objects) emit the same
    # under both flags.
    def emit_json(payload, opts)
      if opts[:ndjson] && payload.is_a?(Array)
        payload.each { |item| stdout.puts JSON.generate(item) }
      else
        stdout.puts JSON.generate(payload)
      end
    end

    def emit_sections(data, sections)
      multi = sections.size > 1
      sections.each_with_index do |sec, i|
        stdout.puts if i > 0
        stdout.puts "# #{sec}" if multi
        case sec
        when :parse     then emit_parse_human(data[:parse])
        when :canonical then stdout.puts data[:canonical]
        when :normalize then stdout.puts data[:normalize]
        when :explain   then emit_explain_human(data[:explain])
        end
      end
    end

    # Render the trace hash as a vertically-aligned per-segment table.
    # path rows first, then query rows.
    def emit_explain_human(trace)
      stdout.puts trace[:normalized]
      emit_trace_section("path",  trace[:path])
      emit_trace_section("query", trace[:query]) if trace[:query]
    end

    def emit_trace_section(label, rows)
      return if rows.nil? || rows.empty?

      stdout.puts
      stdout.puts "#{label}:"
      name_width  = rows.map { |r| trace_label(r).length }.max
      type_width  = rows.map { |r| r[:type].to_s.length }.max
      out_width   = rows.map { |r| r[:output].to_s.length }.max
      rows.each do |r|
        stdout.puts "  #{trace_label(r).ljust(name_width)}  #{r[:type].to_s.ljust(type_width)}  #{r[:output].to_s.ljust(out_width)}#{format_notes(r[:notes])}"
      end
    end

    def trace_label(row)
      # Path rows have :value, query rows have :name=:value.
      row[:name] ? "#{row[:name]}=#{row[:value]}" : row[:value].to_s
    end

    def format_notes(notes)
      return "" if notes.nil? || notes.empty?
      "  (" + notes.join("; ") + ")"
    end

    # Render the compact identifier_hash. Keys/values are already filtered;
    # array/hash values get .inspect, everything else .to_s.
    def emit_parse_human(h)
      h.each do |key, value|
        rendered = value.is_a?(Array) || value.is_a?(Hash) ? value.inspect : value.to_s
        stdout.puts "#{"#{key}:".ljust(15)}#{rendered}"
      end
    end

    def emit_clusters(clusters, opts)
      sorted = clusters.sort_by { |c| -c.count }

      if opts[:json]
        emit_json(sorted.map(&:to_h), opts)
      else
        sorted.each_with_index do |c, i|
          stdout.puts if i > 0
          host  = c.host || "(urn)"
          shape = opts[:hints] ? c.shape : raw_shape_for(c)
          stdout.puts "[#{c.count}] #{host}  #{shape}"
          examples = c.examples.first(3)
          examples.each { |e| stdout.puts "    #{e.canonical}" }
          remaining = c.count - examples.size
          stdout.puts "    + #{remaining} more" if remaining.positive?
          emit_param_summary(c)
        end
      end
    end

    # One line per param: type, range (numeric), cardinality, presence.
    # `page  integer  1..100  avg 50.5  (10 distinct, 100%)`
    def emit_param_summary(cluster)
      rows = cluster.param_summary
      return if rows.empty?

      width = rows.map { |r| r[:name].length }.max
      rows.each do |r|
        bits = ["#{r[:type]}"]
        if r[:min] && r[:max]
          bits << format_range(r[:min], r[:max])
          bits << "avg #{format_num(r[:avg])}" if r[:avg]
        end
        bits << "(#{r[:cardinality]} distinct, #{format_pct(r[:presence])})"
        stdout.puts "    #{r[:name].to_s.ljust(width)}  #{bits.join('  ')}"
      end
    end

    def format_range(lo, hi)
      "#{format_num(lo)}..#{format_num(hi)}"
    end

    def format_num(n)
      return n.to_s if n.is_a?(Integer)
      whole = n.to_i
      return whole.to_s if whole == n
      n.round(2).to_s
    end

    def format_pct(frac)
      "#{(frac * 100).round}%"
    end

    def raw_shape_for(cluster)
      example = cluster.examples.first
      return cluster.shape unless example

      PathShape.for(example.path_segments, hints: false)
    end

    def emit_stats(corpus, opts)
      payload = {
        observations: corpus.host_counts.values.sum,
        clusters:     corpus.size,
        hosts:        top(corpus.host_counts),
        shapes:       top(corpus.fingerprint_counts),
        raw_shapes:   top(corpus.raw_shape_counts),
      }

      if opts[:json]
        stdout.puts JSON.generate(payload)
      else
        stdout.puts "observations: #{payload[:observations]}"
        stdout.puts "clusters:     #{payload[:clusters]}"
        stdout.puts
        stdout.puts "top hosts:"
        payload[:hosts].each { |h, n| stdout.puts "  #{n.to_s.rjust(6)}  #{h}" }
        stdout.puts
        stdout.puts "top shapes:"
        shapes = opts[:hints] ? payload[:shapes] : payload[:raw_shapes]
        shapes.each { |s, n| stdout.puts "  #{n.to_s.rjust(6)}  #{s}" }
      end
    end

    def top(hash)
      # Lex tie-break on equal counts — Ruby Hash insertion order would
      # otherwise diverge from Go's map iteration (which has no insertion
      # order). Keeps Ruby ↔ Go --stats parity stable.
      hash.sort_by { |k, n| [-n, k] }.first(TOP_N_STATS).to_h
    end
  end
end
