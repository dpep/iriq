require "json"
require "optparse"

module Iriq
  # Tiny CLI wrapper around the public API. Construct with explicit IO so
  # specs can run it without shelling out.
  class CLI
    COMMANDS = %w[parse normalize explain classify cluster help version].freeze

    USAGE = <<~TXT
      Usage: iriq <command> [options] [args]

      Commands:
        parse <input>          Parse an identifier and print its fields
        normalize <input>      Print the shape-normalized form
        explain <input>        Annotate each path segment
        classify <segment>     Classify a single segment
        cluster [file]         Cluster identifiers from FILE or stdin (one per line)
        help                   Show this message
        version                Print version

      Options:
        -j, --json             Emit JSON instead of human-readable output
        -h, --help             Show this message

      Examples:
        iriq parse https://foo.com/users/123
        iriq normalize foo.com/users/456
        echo "https://foo.com/users/1\\nhttps://foo.com/users/2" | iriq cluster
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

      cmd = args.shift
      return print_usage(stdout, 0) if cmd.nil? || cmd == "help" || opts[:help]

      unless COMMANDS.include?(cmd)
        stderr.puts "iriq: unknown command #{cmd.inspect}"
        print_usage(stderr, 1)
        return 1
      end

      send("cmd_#{cmd}", args, opts)
    rescue Iriq::ParseError => e
      stderr.puts "iriq: parse error: #{e.message}"
      2
    rescue OptionParser::ParseError => e
      stderr.puts "iriq: #{e.message}"
      1
    end

    private

    def parse_options(argv)
      opts = { json: false, help: false }
      parser = OptionParser.new do |o|
        o.on("-j", "--json") { opts[:json] = true }
        o.on("-h", "--help") { opts[:help] = true }
      end
      args = parser.parse(argv)
      [args, opts]
    end

    def print_usage(io, code)
      io.puts USAGE
      code
    end

    def require_arg!(args, name)
      return args.first if args.first

      stderr.puts "iriq: missing argument <#{name}>"
      throw :missing_arg, 1
    end

    def cmd_version(_args, _opts)
      stdout.puts Iriq::VERSION
      0
    end

    def cmd_parse(args, opts)
      input = args.first or return missing(:input)
      iri   = Iriq.parse(input)
      emit_parse(iri, opts)
      0
    end

    def cmd_normalize(args, opts)
      input = args.first or return missing(:input)
      out   = Iriq.normalize(input)
      opts[:json] ? stdout.puts(JSON.generate(normalized: out)) : stdout.puts(out)
      0
    end

    def cmd_explain(args, opts)
      input = args.first or return missing(:input)
      rows  = Iriq.explain(input)
      if opts[:json]
        stdout.puts JSON.generate(rows)
      else
        rows.each do |r|
          mark = r[:variable] ? "*" : " "
          stdout.printf("%s %-12s %s\n", mark, r[:type], r[:value])
        end
      end
      0
    end

    def cmd_classify(args, opts)
      seg  = args.first or return missing(:segment)
      type = SegmentClassifier.new.classify(seg)
      opts[:json] ? stdout.puts(JSON.generate(value: seg, type: type)) : stdout.puts(type)
      0
    end

    def cmd_cluster(args, opts)
      lines = read_input(args.first)
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

    def cmd_help(_args, _opts)
      print_usage(stdout, 0)
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

    def emit_parse(iri, opts)
      if opts[:json]
        stdout.puts JSON.generate(
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
        )
      else
        stdout.puts "original:      #{iri.original}"
        stdout.puts "kind:          #{iri.kind}"
        stdout.puts "scheme:        #{iri.scheme}" if iri.scheme
        stdout.puts "host:          #{iri.host}"   if iri.host
        stdout.puts "port:          #{iri.port}"   if iri.port
        stdout.puts "path_segments: #{iri.path_segments.inspect}" if iri.url?
        unless iri.query_params.empty?
          stdout.puts "query_params:  #{iri.query_params.inspect}"
        end
        stdout.puts "fragment:      #{iri.fragment}" if iri.fragment
        stdout.puts "nss:           #{iri.nss}"      if iri.nss
        stdout.puts "canonical:     #{iri.canonical}"
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
