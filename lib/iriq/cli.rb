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

      batch_mode = explicit_cluster || (args.empty? && piped_stdin?)

      return print_usage(stdout, 0) if args.empty? && !batch_mode

      corpus = opts[:corpus] ? load_corpus(opts[:corpus]) : nil

      code = if batch_mode
        cmd_batch(args, opts, corpus)
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
        json:     false,
        help:     false,
        version:  false,
        hints:    true,
        sections: [],
        corpus:   nil,
        stats:    false,
      }
      parser = OptionParser.new do |o|
        o.on("-p", "--parse")     { opts[:sections] << :parse }
        o.on("-n", "--normalize") { opts[:sections] << :normalize }
        o.on("-e", "--explain")   { opts[:sections] << :explain }
        o.on("-j", "--json")      { opts[:json]    = true }
        o.on("--[no-]hints")      { |v| opts[:hints] = v }
        o.on("--corpus PATH")     { |v| opts[:corpus] = v }
        o.on("--stats")           { opts[:stats]   = true }
        o.on("-h", "--help")      { opts[:help]    = true }
        o.on("-V", "--version")   { opts[:version] = true }
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

    def cmd_batch(args, opts, corpus)
      corpus ||= Corpus.new
      lines = read_input(args.first)
      lines.each do |line|
        line = line.strip
        next if line.empty?

        begin
          corpus.observe(line)
        rescue Iriq::ParseError => e
          stderr.puts "iriq: skipped #{line.inspect}: #{e.message}"
        end
      end

      if opts[:stats]
        emit_stats(corpus, opts)
      else
        emit_clusters(corpus.clusters, opts)
      end
      0
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
