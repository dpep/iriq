require "json"
require "optparse"

module Iriq
  # Flag-driven CLI. The default action for an input is a combined parse +
  # normalize + explain summary; the -p/-n/-e flags select individual
  # sections. The only subcommand is `cluster`, which is structurally
  # different (many inputs, not one). Construct with explicit IO so specs
  # can run it without shelling out.
  class CLI
    SECTION_FLAGS = %i[parse normalize explain].freeze

    USAGE = <<~TXT
      Usage: iriq [options] <input>
             iriq cluster [options] [file]

      With no section flag, prints all three sections for <input>.

      Section flags (combine freely):
        -p, --parse           Show parsed fields
        -n, --normalize       Show the shape-normalized form
        -e, --explain         Show per-segment annotations

      Other options:
        -j, --json            Emit JSON instead of human-readable output
            --no-hints        Use mechanical placeholders ({integer_id}) instead of {user_id}
        -h, --help            Show this message
        -V, --version         Print version

      Cluster command:
        iriq cluster [file]   Cluster identifiers from FILE or stdin (one per line)

      Examples:
        iriq foo.com/users/456
        iriq -n https://foo.com/users/123
        iriq -pe foo.com/posts/2024-05-23/hello
        cat urls.txt | iriq cluster --json
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
      return print_usage(stdout, 0) if args.empty? && opts[:sections].empty?

      if args.first == "cluster"
        args.shift
        cmd_cluster(args, opts)
      else
        cmd_summary(args, opts)
      end
    rescue Iriq::ParseError => e
      stderr.puts "iriq: parse error: #{e.message}"
      2
    rescue OptionParser::ParseError => e
      stderr.puts "iriq: #{e.message}"
      1
    end

    private

    def parse_options(argv)
      opts = { json: false, help: false, version: false, hints: true, sections: [] }
      parser = OptionParser.new do |o|
        o.on("-p", "--parse")     { opts[:sections] << :parse }
        o.on("-n", "--normalize") { opts[:sections] << :normalize }
        o.on("-e", "--explain")   { opts[:sections] << :explain }
        o.on("-j", "--json")      { opts[:json]    = true }
        o.on("--[no-]hints")      { |v| opts[:hints] = v }
        o.on("-h", "--help")      { opts[:help]    = true }
        o.on("-V", "--version")   { opts[:version] = true }
      end
      args = parser.parse(argv)
      [args, opts]
    end

    def print_usage(io, code)
      io.puts USAGE
      code
    end

    def print_version
      stdout.puts Iriq::VERSION
      0
    end

    def cmd_summary(args, opts)
      input = args.first or return missing(:input)
      iri   = Iriq.parse(input)
      sections = opts[:sections].empty? ? SECTION_FLAGS : opts[:sections]

      data = {}
      data[:parse]     = identifier_hash(iri)                         if sections.include?(:parse)
      data[:normalize] = Normalizer.normalize_identifier(iri, hints: opts[:hints]) if sections.include?(:normalize)
      data[:explain]   = Explanation.explain(iri)                      if sections.include?(:explain)

      if opts[:json]
        payload = sections.size == 1 ? data.values.first : data
        stdout.puts JSON.generate(payload)
      else
        emit_sections(data, sections)
      end
      0
    end

    def cmd_cluster(args, opts)
      lines     = read_input(args.first)
      clusterer = Clusterer.new
      lines.each do |line|
        line = line.strip
        next if line.empty?

        begin
          clusterer.add(line)
        rescue Iriq::ParseError => e
          stderr.puts "iriq: skipped #{line.inspect}: #{e.message}"
        end
      end
      emit_clusters(clusterer.clusters, opts)
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
        stdout.printf("%s %-12s %-12s %s\n", mark, r[:type], placeholder, r[:value])
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
  end
end
