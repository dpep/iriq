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
    SECTION_FLAGS = %i[parse normalize explain].freeze
    TOP_N_STATS   = 10

    # When extraction yields this many or more IRIs, the default pipe
    # output switches from a URL list to clusters — a longer list is
    # easier to read as route-shape groups.
    LARGE_BATCH_THRESHOLD = 10

    USAGE = <<~TXT
      Usage: iriq [options] <input>
             iriq [options] < urls.txt
             iriq cluster [options] [file]

      With a positional input: prints parse + normalize + explain (or just the
      sections you select with -p/-n/-e). With piped stdin and no positional:
      processes each line as an input (batch mode) and prints clusters at the
      end (or stats with --stats).

      Section flags (combine freely):
        -p, --parse           Show parsed fields
        -n, --normalize       Show the shape-normalized form
        -e, --explain         Show per-segment annotations

      Corpus + streaming:
            --corpus PATH     Load/create a JSON-backed corpus at PATH. Each
                              observed IRI updates it; the file is rewritten
                              atomically on exit. With --corpus, normalize and
                              explain are corpus-informed.
            --stats           Print rolling aggregates instead of clusters

      Extraction from free text:
            --extract         Treat input as prose; pull URLs/URNs out and emit
                              them one per line (combine with --corpus to feed
                              the corpus, --json for machine output).
            --scheme-less     Also extract scheme-less URLs like foo.com/path
                              (conservative TLD allow-list; requires a path)

      Other options:
        -j, --json            Emit JSON instead of human-readable output
            --no-hints        Use mechanical placeholders ({integer_id})
        -h, --help            Show this message
        -V, --version         Print version

      Subcommands:
        iriq cluster [file]   Cluster identifiers from FILE or stdin (alias for
                              piped batch mode)

      Examples:
        iriq foo.com/users/456
        iriq -n https://foo.com/users/123
        cat urls.txt | iriq
        cat urls.txt | iriq --corpus mycorpus.json --stats
        iriq --corpus mycorpus.json https://foo.com/users/1
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

      # Pipe / batch mode kicks in when stdin is piped without a positional
      # input, or when `cluster` is named explicitly.
      batch_mode = explicit_cluster || (args.empty? && piped_stdin? && !opts[:extract])

      return print_usage(stdout, 0) if args.empty? && !batch_mode && !opts[:extract]

      corpus = opts[:corpus] ? load_corpus(opts[:corpus]) : nil

      code = if opts[:extract]
        cmd_extract(args, opts, corpus)
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
      stderr.puts "iriq: parse error: #{e.message}"
      2
    rescue OptionParser::ParseError => e
      stderr.puts "iriq: #{e.message}"
      1
    end

    private

    def parse_options(argv)
      opts = {
        json:        false,
        help:        false,
        version:     false,
        hints:       true,
        sections:    [],
        corpus:      nil,
        stats:       false,
        extract:     false,
        scheme_less: true,
      }
      parser = OptionParser.new do |o|
        o.on("-p", "--parse")        { opts[:sections] << :parse }
        o.on("-n", "--normalize")    { opts[:sections] << :normalize }
        o.on("-e", "--explain")      { opts[:sections] << :explain }
        o.on("-j", "--json")         { opts[:json]    = true }
        o.on("--[no-]hints")         { |v| opts[:hints] = v }
        o.on("--corpus PATH")        { |v| opts[:corpus] = v }
        o.on("--stats")              { opts[:stats]   = true }
        o.on("--extract")            { opts[:extract] = true }
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

    def load_corpus(path)
      return Corpus.load(path) if File.exist?(path)

      Corpus.new
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
      obs      = corpus&.observe(iri)
      sections = opts[:sections].empty? ? SECTION_FLAGS : opts[:sections]

      data = {}
      data[:parse]     = identifier_hash(iri)                                                if sections.include?(:parse)
      data[:normalize] = (corpus ? corpus.normalize(iri) : Normalizer.normalize_identifier(iri, hints: opts[:hints])) if sections.include?(:normalize)
      data[:explain]   = (obs ? obs.explanation : Explanation.explain(iri))                  if sections.include?(:explain)

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
      iris.each { |iri| corpus.observe(iri) }

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

    def extract_text(text, opts)
      Extractor.new(scheme_less: opts[:scheme_less]).extract(text)
    end

    def cmd_extract(args, opts, corpus)
      iris = extract_text(read_text(args.first), opts)
      iris.each { |iri| corpus.observe(iri) } if corpus

      if opts[:stats] && corpus
        emit_stats(corpus, opts)
      else
        emit_url_list(iris, opts)
      end
      0
    end

    # Emit a deduplicated list of IRIs with occurrence counts, sorted desc
    # by count then by first-seen order. Useful default for "what URLs are
    # in this text?" questions.
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
        stdout.puts JSON.generate(sorted.map { |k, c| { iri: k, count: c } })
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
      }
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

    def emit_parse_human(h)
      stdout.puts "original:      #{h[:original]}"
      stdout.puts "kind:          #{h[:kind]}"
      stdout.puts "scheme:        #{h[:scheme]}" if h[:scheme]
      stdout.puts "host:          #{h[:host]}"   if h[:host]
      stdout.puts "port:          #{h[:port]}"   if h[:port]
      stdout.puts "path_segments: #{h[:path_segments].inspect}" if h[:kind] == :url
      stdout.puts "query_params:  #{h[:query_params].inspect}" if h[:query_params] && !h[:query_params].empty?
      stdout.puts "fragment:      #{h[:fragment]}" if h[:fragment]
      stdout.puts "nss:           #{h[:nss]}"      if h[:nss]
      stdout.puts "canonical:     #{h[:canonical]}"
    end

    def emit_explain_human(rows)
      rows.each do |r|
        mark        = r[:variable] ? "*" : " "
        placeholder = r[:hint] || r[:type]
        extras      = []
        extras << r[:classification] if r[:classification]
        suffix = extras.empty? ? "" : "  [#{extras.join(', ')}]"
        stdout.printf("%s %-12s %-12s %s%s\n", mark, r[:type], placeholder, r[:value], suffix)
      end
    end

    def emit_clusters(clusters, opts)
      sorted = clusters.sort_by { |c| -c.count }

      if opts[:json]
        stdout.puts JSON.generate(sorted.map(&:to_h))
      else
        sorted.each do |c|
          host = c.host || "(urn)"
          stdout.puts "[#{c.count}] #{host}  #{c.shape}"
          c.examples.first(3).each { |e| stdout.puts "    #{e.canonical}" }
          stdout.puts "    + #{c.count - 3} more" if c.count > 3
        end
      end
    end

    def emit_stats(corpus, opts)
      payload = {
        observations:  corpus.host_counts.values.sum,
        clusters:      corpus.size,
        hosts:         top(corpus.host_counts),
        path_lengths:  corpus.path_length_counts.sort.to_h,
        shapes:        top(corpus.fingerprint_counts),
        raw_shapes:    top(corpus.raw_shape_counts),
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
        stdout.puts "path lengths:"
        payload[:path_lengths].each { |len, n| stdout.puts "  #{n.to_s.rjust(6)}  #{len}" }
        stdout.puts
        stdout.puts "top shapes:"
        payload[:shapes].each { |s, n| stdout.puts "  #{n.to_s.rjust(6)}  #{s}" }
      end
    end

    def top(hash)
      hash.sort_by { |_, n| -n }.first(TOP_N_STATS).to_h
    end
  end
end
