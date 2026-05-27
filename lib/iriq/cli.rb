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
      Usage: iriq [options] <input>
             iriq [options] < text
             iriq cluster [options] [file]

      <input> may be an IRI, a file path (extracted automatically), or piped
      text via stdin.

      Sections (combine freely):
        -n, --normalize       Shape-normalized form
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
      args, opts = parse_options(argv)

      return print_usage(stdout, 0) if opts[:help]
      return print_version          if opts[:version]

      explicit_cluster = (args.first == "cluster")
      args.shift if explicit_cluster

      # Auto-detect: a positional argument that isn't parseable as an IRI
      # but IS an existing file gets treated as a file to extract from. This
      # is what makes `iriq ./access.log` and `iriq /var/log/foo.log` Just
      # Work without a separate --extract flag.
      positional_is_file = args.first && File.file?(args.first) && !parseable_iri?(args.first)

      batch_mode = explicit_cluster || positional_is_file ||
                   (args.empty? && piped_stdin?)

      return print_usage(stdout, 0) if args.empty? && !batch_mode

      corpus = opts[:corpus] ? load_corpus(opts[:corpus], host_strategy: opts[:host_strategy]) : nil

      code = if batch_mode
        cmd_batch(args, opts, corpus, explicit_cluster: explicit_cluster)
      elsif opts[:stats]
        cmd_stats(corpus, opts)
      else
        cmd_summary(args, opts, corpus)
      end

      corpus.save(opts[:corpus]) if corpus && opts[:corpus]
      code
    rescue Iriq::ParseError => e
      stderr.puts "iriq: parse error: #{e.message}"
      2
    rescue OptionParser::ParseError => e
      stderr.puts "iriq: #{e.message}"
      1
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
        scheme_less:   true,
        host_strategy: :full,
      }
      parser = OptionParser.new do |o|
        o.on("-p", "--parse")        { opts[:sections] << :parse }
        o.on("-n", "--normalize")    { opts[:sections] << :normalize }
        o.on("-e", "--explain")      { opts[:sections] << :explain }
        o.on("-j", "--json")         { opts[:json]    = true }
        o.on("-J", "--ndjson")       { opts[:json]    = true; opts[:ndjson] = true }
        o.on("--[no-]hints")         { |v| opts[:hints] = v }
        o.on("-N")                   { opts[:hints] = false }
        o.on("--corpus PATH")        { |v| opts[:corpus] = v }
        o.on("--host MODE")          { |v| opts[:host_strategy] = host_strategy_arg(v) }
        o.on("--stats")              { opts[:stats]   = true }
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
      iris = extract_text(read_text(args.first), opts)
      corpus.batch { iris.each { |iri| corpus.observe(iri) } }

      if opts[:sections].any?
        emit_per_iri_sections(iris, opts)
      elsif opts[:stats]
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

    # Emit the requested sections (parse/normalize/explain) for each
    # extracted IRI. -n alone is the cleanest case: one line per URL.
    def emit_per_iri_sections(iris, opts)
      sections = opts[:sections]
      payloads = iris.map { |iri| section_payload(iri, sections, opts) }

      if opts[:json]
        out = sections.size == 1 ? payloads.map(&:values).flatten(1) : payloads
        emit_json(out, opts)
      elsif sections == [:normalize]
        # Most common case — keep it tight: one URL per line, no headers.
        payloads.each { |p| stdout.puts p[:normalize] }
      else
        payloads.each_with_index do |p, i|
          stdout.puts if i > 0
          stdout.puts "# #{iris[i].canonical}"
          sections.each_with_index do |sec, j|
            stdout.puts if j > 0  # blank line between sections within one IRI
            case sec
            when :parse     then emit_parse_human(p[:parse])
            when :normalize then stdout.puts p[:normalize]
            end
          end
        end
      end
    end

    def section_payload(iri, sections, opts)
      data = {}
      data[:parse]     = identifier_hash(iri)                                       if sections.include?(:parse)
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

    def missing(name)
      stderr.puts "iriq: missing argument <#{name}>"
      1
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
          c.examples.first(3).each { |e| stdout.puts "    #{e.canonical}" }
          stdout.puts "    + #{c.count - 3} more" if c.count > 3
        end
      end
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
