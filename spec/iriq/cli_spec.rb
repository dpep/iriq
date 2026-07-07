require "json"
require "stringio"

describe Iriq::CLI do
  let(:stdin)  { StringIO.new }
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  subject(:cli) { described_class.new(stdin: stdin, stdout: stdout, stderr: stderr) }

  def run(*args)
    cli.run(args)
  end

  describe "help / usage / version" do
    it "prints usage with no args" do
      expect(run).to eq(0)
      expect(stdout.string).to include("Usage: iriq")
    end

    it "prints usage on --help" do
      expect(run("--help")).to eq(0)
      expect(stdout.string).to include("Usage: iriq")
    end

    it "prints the version on --version" do
      expect(run("--version")).to eq(0)
      expect(stdout.string.strip).to eq(Iriq::VERSION)
    end

    it "errors on parse failure with exit code 2" do
      expect(run("just-some-token")).to eq(2)
      expect(stderr.string).to include("parse error")
    end

    it "errors on unknown option with exit code 1" do
      expect(run("--frobnicate")).to eq(1)
      expect(stderr.string).to include("invalid option")
    end
  end

  describe "JSON error envelope" do
    def error_payload
      JSON.parse(stderr.string)
    end

    it "emits a structured parse error to stderr under --json" do
      expect(run("--json", "just-some-token")).to eq(2)
      expect(stdout.string).to be_empty
      expect(error_payload).to match("error" => { "code" => "parse_error", "message" => be_a(String) })
    end

    it "wraps an unknown option as an option_error" do
      expect(run("--json", "--frobnicate")).to eq(1)
      expect(error_payload.dig("error", "code")).to eq("option_error")
    end

    it "wraps a missing required argument" do
      # Corpus operations require a corpus. With auto-corpus on the default
      # path, an explicit --no-corpus exposes the same error path.
      expect(run("--propose-recognizers", "--no-corpus", "--json")).to eq(1)
      expect(error_payload["error"]).to include("code" => "missing_argument", "message" => "missing argument <--corpus>")
    end

    it "wraps an unknown completion shell" do
      expect(run("completion", "tcsh", "--json")).to eq(1)
      expect(error_payload.dig("error", "code")).to eq("unknown_shell")
    end

    it "honors the bundled short -J flag on the error path" do
      expect(run("-nJ", "just-some-token")).to eq(2)
      expect(error_payload.dig("error", "code")).to eq("parse_error")
    end

    it "keeps the plain human error without --json" do
      expect(run("just-some-token")).to eq(2)
      expect(stderr.string).to start_with("iriq: parse error:")
    end
  end

  describe "completion" do
    %w[bash zsh fish].each do |shell|
      it "emits the bundled #{shell} script" do
        expect(run("completion", shell)).to eq(0)
        expect(stdout.string).to eq(File.read(Iriq::CLI::COMPLETION_FILES[shell]))
      end
    end

    it "errors on an unknown shell" do
      expect(run("completion", "tcsh")).to eq(1)
      expect(stderr.string).to include("unknown shell")
    end
  end

  describe "default (no section flag)" do
    it "runs parse + normalize for a URL-ish input" do
      expect(run("foo.com/users/123")).to eq(0)
      out = stdout.string
      expect(out).to include("# parse")
      expect(out).to include("scheme:        https")
      expect(out).to include("host:          foo.com")
      expect(out).to include("# normalize")
      expect(out).to include("https://foo.com/users/{user_id}")
    end

    it "emits a single combined JSON object with --json" do
      expect(run("--json", "https://foo.com/users/123")).to eq(0)
      data = JSON.parse(stdout.string)
      expect(data.keys).to contain_exactly("parse", "normalize")
      expect(data["parse"]).to include("host" => "foo.com")
      expect(data["normalize"]).to eq("https://foo.com/users/{user_id}")
    end

    it "works for URNs" do
      expect(run("urn:isbn:0451450523")).to eq(0)
      out = stdout.string
      expect(out).to include("kind:          urn")
      expect(out).to include("urn:isbn:{isbn_id}")
    end
  end

  describe "section flags" do
    it "prints only the parse section with -p" do
      expect(run("-p", "https://foo.com/users/123")).to eq(0)
      out = stdout.string
      expect(out).to include("scheme:        https")
      expect(out).not_to include("# normalize")
    end

    it "prints only the normalize section with -n" do
      expect(run("-n", "foo.com/users/123")).to eq(0)
      expect(stdout.string.strip).to eq("https://foo.com/users/{user_id}")
    end

    it "combines flags (-pn) and shows section headers" do
      expect(run("-pn", "https://foo.com/users/123")).to eq(0)
      out = stdout.string
      expect(out).to include("# parse")
      expect(out).to include("# normalize")
    end

    it "prints only the canonical section with -c, no shape normalization" do
      expect(run("-c", "HTTP://Foo.COM/users/123")).to eq(0)
      expect(stdout.string.strip).to eq("http://foo.com/users/123")
    end

    it "returns just the canonical string under -c --json" do
      expect(run("-c", "--json", "foo.com/users/123")).to eq(0)
      expect(JSON.parse(stdout.string)).to eq("https://foo.com/users/123")
    end

    it "combines -cn into separate canonical and normalize sections" do
      expect(run("-cn", "foo.com/users/123")).to eq(0)
      out = stdout.string
      expect(out).to include("# canonical")
      expect(out).to include("https://foo.com/users/123")
      expect(out).to include("# normalize")
      expect(out).to include("https://foo.com/users/{user_id}")
    end

    it "with --json and a single section, returns just that section's payload" do
      expect(run("-n", "--json", "foo.com/users/123")).to eq(0)
      expect(JSON.parse(stdout.string)).to eq("https://foo.com/users/{user_id}")
    end

    it "with --json and multiple sections, bundles them" do
      expect(run("-pn", "--json", "foo.com/users/123")).to eq(0)
      data = JSON.parse(stdout.string)
      expect(data.keys).to contain_exactly("parse", "normalize")
    end

    it "orders multi-section JSON keys consistently regardless of flag order" do
      # Fixed emission order (parse, canonical, normalize) — not the order the
      # flags were typed — so the Go port can pin the same order for parity.
      expect(run("-nc", "--json", "foo.com/users/123")).to eq(0)
      expect(JSON.parse(stdout.string).keys).to eq(%w[canonical normalize])
      stdout.truncate(stdout.rewind)
      expect(run("-pcn", "--json", "foo.com/users/123")).to eq(0)
      expect(JSON.parse(stdout.string).keys).to eq(%w[parse canonical normalize])
    end
  end

  describe "--no-hints" do
    it "uses mechanical placeholders" do
      expect(run("-n", "--no-hints", "foo.com/users/123")).to eq(0)
      expect(stdout.string.strip).to eq("https://foo.com/users/{integer}")
    end
  end

  describe "pipe (batch) mode" do
    it "treats piped stdin with no positional as extract → URL list" do
      stdin.string = <<~LINES
        https://foo.com/users/1
        https://foo.com/users/2
        https://foo.com/posts/abc-123/edit
      LINES

      expect(run).to eq(0)
      out = stdout.string
      # All unique → no [count] prefix
      expect(out).to include("https://foo.com/users/1")
      expect(out).to include("https://foo.com/users/2")
      expect(out).to include("https://foo.com/posts/abc-123/edit")
      expect(out).not_to include("[1]")
    end

    it "deduplicates with counts when any duplicates exist" do
      stdin.string = "https://foo.com\nhttps://foo.com\nhttps://bar.com\n"
      expect(run).to eq(0)
      lines = stdout.string.lines.map(&:chomp)
      expect(lines).to eq(["[2] https://foo.com", "[1] https://bar.com"])
    end

    it "drops the [1] prefix when every IRI is unique" do
      stdin.string = "https://foo.com and https://bar.com and https://baz.com"
      expect(run).to eq(0)
      lines = stdout.string.lines.map(&:chomp)
      expect(lines).to eq(["https://foo.com", "https://bar.com", "https://baz.com"])
    end

    it "extracts URLs from prose, not just URL-per-line" do
      stdin.string = "Visit https://foo.com today. See also (https://bar.com)."
      expect(run).to eq(0)
      out = stdout.string
      expect(out).to include("https://foo.com")
      expect(out).to include("https://bar.com")
    end

    it "silently drops non-URL lines (no parse-error noise)" do
      stdin.string = "https://foo.com\nnot-a-url\nhttps://bar.com\n"
      expect(run).to eq(0)
      expect(stderr.string).to be_empty
      expect(stdout.string).to include("https://foo.com")
      expect(stdout.string).to include("https://bar.com")
    end

    it "prints --stats instead of URL list when requested" do
      stdin.string = "https://foo.com/users/1\nhttps://foo.com/users/2\nhttps://bar.com/x\n"
      expect(run("--stats")).to eq(0)
      out = stdout.string
      expect(out).to include("observations: 3")
      expect(out).to include("top hosts:")
      expect(out).to match(/2\s+foo\.com/)
      expect(out).to match(/1\s+bar\.com/)
    end

    it "the cluster keyword still prints clusters" do
      stdin.string = "https://foo.com/users/1\nhttps://foo.com/users/2\n"
      expect(run("cluster")).to eq(0)
      expect(stdout.string).to include("[2] foo.com  /users/{user_id}")
    end

    it "emits JSON stats when --stats and --json combine" do
      stdin.string = "https://foo.com/users/1\n"
      expect(run("--stats", "--json")).to eq(0)
      data = JSON.parse(stdout.string)
      expect(data["observations"]).to eq(1)
      expect(data["hosts"]).to eq("foo.com" => 1)
    end

    it "emits JSON URL list with --json (default output)" do
      stdin.string = "see https://foo.com and https://foo.com again"
      expect(run("--json")).to eq(0)
      expect(JSON.parse(stdout.string)).to eq([{ "iri" => "https://foo.com", "count" => 2 }])
    end

    describe "section flags in pipe mode" do
      it "-n prints one normalized URL per extracted IRI" do
        stdin.string = "see https://foo.com/users/1 and (https://foo.com/users/2)"
        expect(run("-n")).to eq(0)
        expect(stdout.string.lines.map(&:chomp)).to eq([
          "https://foo.com/users/{user_id}",
          "https://foo.com/users/{user_id}",
        ])
      end

      it "streams the sections path lazily, without slurping stdin" do
        # A stdin that raises if read in full — proves -n consumes it line by
        # line (so `tail -f | iriq -n` flows) rather than buffering everything.
        no_slurp = Class.new(StringIO) do
          def read(*) = raise("slurped stdin instead of streaming line by line")
        end.new("https://foo.com/users/1\nhttps://foo.com/users/2\n")
        out = StringIO.new
        code = described_class.new(stdin: no_slurp, stdout: out, stderr: StringIO.new).run(["-n"])
        expect(code).to eq(0)
        expect(out.string.lines.map(&:chomp)).to eq([
          "https://foo.com/users/{user_id}",
          "https://foo.com/users/{user_id}",
        ])
      end

      it "-n --json emits a flat array of normalized strings" do
        stdin.string = "see https://foo.com/users/1 and https://foo.com/users/2"
        expect(run("-n", "--json")).to eq(0)
        expect(JSON.parse(stdout.string)).to eq([
          "https://foo.com/users/{user_id}",
          "https://foo.com/users/{user_id}",
        ])
      end

      it "-c prints one canonical URL per extracted IRI" do
        stdin.string = "see https://foo.com/users/1 and (https://foo.com/users/2)"
        expect(run("-c")).to eq(0)
        expect(stdout.string.lines.map(&:chomp)).to eq([
          "https://foo.com/users/1",
          "https://foo.com/users/2",
        ])
      end

      it "-c --json emits a flat array of canonical strings" do
        stdin.string = "see https://foo.com/users/1 and https://foo.com/users/2"
        expect(run("-c", "--json")).to eq(0)
        expect(JSON.parse(stdout.string)).to eq([
          "https://foo.com/users/1",
          "https://foo.com/users/2",
        ])
      end

      it "-n --ndjson emits one JSON value per line" do
        stdin.string = "see https://foo.com/users/1 and https://foo.com/users/2"
        expect(run("-n", "--ndjson")).to eq(0)
        lines = stdout.string.lines.map(&:chomp)
        expect(lines).to eq([
          '"https://foo.com/users/{user_id}"',
          '"https://foo.com/users/{user_id}"',
        ])
      end

      it "--ndjson on cluster output emits one cluster per line" do
        stdin.string = (1..11).map { |n| "https://foo.com/users/#{n}" }.join("\n")
        expect(run("--ndjson")).to eq(0)
        lines = stdout.string.lines.map(&:chomp)
        expect(lines.size).to eq(1)
        parsed = JSON.parse(lines.first)
        expect(parsed["shape"]).to eq("/users/{user_id}")
        expect(parsed["count"]).to eq(11)
      end

      it "--ndjson on the url-list view emits one {iri,count} per line" do
        stdin.string = "https://foo.com\nhttps://foo.com\nhttps://bar.com\n"
        expect(run("--ndjson")).to eq(0)
        parsed = stdout.string.lines.map { |l| JSON.parse(l) }
        expect(parsed).to eq([
          { "iri" => "https://foo.com", "count" => 2 },
          { "iri" => "https://bar.com", "count" => 1 },
        ])
      end

      it "-p prints parse output per IRI with a header" do
        stdin.string = "see https://foo.com/users/1"
        expect(run("-p")).to eq(0)
        out = stdout.string
        expect(out).to include("# https://foo.com/users/1")
        expect(out).to include("scheme:        https")
        expect(out).to include("host:          foo.com")
      end

      it "-p prints parsed details per IRI with a header" do
        stdin.string = "see https://foo.com/users/123 and https://bar.com/x"
        expect(run("-p")).to eq(0)
        out = stdout.string
        expect(out).to include("# https://foo.com/users/123")
        expect(out).to include("# https://bar.com/x")
        expect(out).to include("scheme:        https")
      end

      it "-N (no-hints) gives mechanical placeholders in pipe -n output" do
        stdin.string = "see https://foo.com/users/1"
        expect(run("-n", "-N")).to eq(0)
        expect(stdout.string.strip).to eq("https://foo.com/users/{integer}")
      end

      it "-pn shows a blank line between sections per IRI" do
        stdin.string = "see https://foo.com/users/1"
        expect(run("-pn")).to eq(0)
        out = stdout.string
        # The blank line separates parse fields from the normalize URL.
        expect(out).to match(/canonical:.*\n\n.*\{user_id\}/m)
      end

      it "multiple section flags bundle per IRI in JSON" do
        stdin.string = "see https://foo.com/users/1"
        expect(run("-pn", "--json")).to eq(0)
        data = JSON.parse(stdout.string)
        expect(data.size).to eq(1)
        expect(data.first.keys).to contain_exactly("parse", "normalize")
      end

      it "produces empty output when no URLs found" do
        stdin.string = "no urls here at all"
        expect(run("-n")).to eq(0)
        expect(stdout.string).to eq("")
      end
    end

    it "auto-switches to clusters when input is large (>= LARGE_BATCH_THRESHOLD IRIs)" do
      # 10 URLs that cluster into one shape — cluster view is more useful
      # than a 10-line URL list.
      stdin.string = (1..10).map { |i| "https://foo.com/users/#{i}" }.join("\n")
      expect(run).to eq(0)
      expect(stdout.string).to include("[10] foo.com  /users/{user_id}")
    end

    it "-N renders cluster shapes with mechanical placeholders" do
      stdin.string = (1..10).map { |i| "https://foo.com/users/#{i}" }.join("\n")
      expect(run("-N")).to eq(0)
      expect(stdout.string).to include("[10] foo.com  /users/{integer}")
      expect(stdout.string).not_to include("{user_id}")
    end

    it "cluster output has a blank line between cluster entries" do
      stdin.string = (1..6).map { |i| "https://foo.com/users/#{i}" }.join("\n") +
                     "\n" + (1..4).map { |i| "https://bar.com/x/#{i}" }.join("\n")
      expect(run).to eq(0)
      # Two cluster blocks separated by a blank line.
      blocks = stdout.string.split(/\n\n+/)
      expect(blocks.size).to eq(2)
      expect(blocks[0]).to start_with("[6] foo.com")
      expect(blocks[1]).to start_with("[4] bar.com")
    end

    it "--stats with -N shows raw (hint-free) top shapes" do
      stdin.string = (1..5).map { |i| "https://foo.com/users/#{i}" }.join("\n")
      expect(run("--stats", "-N")).to eq(0)
      expect(stdout.string).to include("/users/{integer}")
      expect(stdout.string).not_to include("{user_id}")
    end

    it "still shows URL list for small inputs" do
      stdin.string = "https://foo.com\nhttps://bar.com"
      expect(run).to eq(0)
      expect(stdout.string).to include("https://foo.com")
      expect(stdout.string).not_to include("foo.com  /")  # no cluster line
    end
  end

  describe "--host" do
    it "accepts 'reg' as a short alias for registrable" do
      file = Tempfile.new(["host-strategy", ".json"])
      begin
        stdin.string = "https://api.foo.com/users/1\nhttps://app.foo.com/users/2\n"
        expect(run("--corpus", file.path, "--host=reg")).to eq(0)
        data = JSON.parse(File.read(file.path))
        expect(data["host_counts"]).to eq("foo.com" => 2)
      ensure
        file.close
        file.unlink
      end
    end

    it "rejects unknown values" do
      stdin.string = ""
      expect(run("--host=bogus")).to eq(1)
      expect(stderr.string).to match(/--host/)
    end
  end

  describe "--corpus" do
    # Hold the Tempfile ref via `let` so its GC finalizer doesn't unlink
    # the corpus file mid-test. See cli_e2e_spec for details.
    let(:corpus_file) do
      f = Tempfile.new(["iriq-corpus", ".json"])
      f.close
      File.delete(f.path) # start fresh
      f
    end
    let(:corpus_path) { corpus_file.path }

    after do
      File.delete(corpus_path) if File.exist?(corpus_path)
    end

    it "creates a new corpus when the file doesn't exist" do
      expect(run("--corpus", corpus_path, "https://foo.com/users/1")).to eq(0)
      expect(File.exist?(corpus_path)).to be true
      data = JSON.parse(File.read(corpus_path))
      expect(data["host_counts"]).to eq("foo.com" => 1)
    end

    it "persists observations across invocations" do
      run("--corpus", corpus_path, "https://foo.com/users/1")

      # Second invocation — separate CLI instance, same file
      stdout.truncate(0); stdout.rewind
      stderr.truncate(0); stderr.rewind
      expect(run("--corpus", corpus_path, "https://foo.com/users/2")).to eq(0)

      data = JSON.parse(File.read(corpus_path))
      expect(data["host_counts"]).to eq("foo.com" => 2)
    end

    it "uses corpus-informed normalize when --corpus is set" do
      # Seed with many distinct names — corpus should promote /users/<name>
      # to a variable in the next invocation.
      %w[alice bob carol dave erin frank gina hank ivan jane].each do |n|
        run("--corpus", corpus_path, "https://foo.com/users/#{n}/profile")
        stdout.truncate(0); stdout.rewind
      end

      expect(run("-n", "--corpus", corpus_path, "https://foo.com/users/zoe/profile")).to eq(0)
      expect(stdout.string.strip).to eq("https://foo.com/users/{user}/profile")
    end

    it "deterministic normalize is unchanged without --corpus" do
      expect(run("-n", "https://foo.com/users/123/profile")).to eq(0)
      expect(stdout.string.strip).to eq("https://foo.com/users/{user_id}/profile")
    end

    it "batch + --corpus accumulates observations from stdin" do
      stdin.string = "https://foo.com/users/1\nhttps://foo.com/users/2\n"
      expect(run("--corpus", corpus_path)).to eq(0)

      data = JSON.parse(File.read(corpus_path))
      expect(data["host_counts"]).to eq("foo.com" => 2)
    end

  end

  describe "file-arg auto-detection (replaces --extract)" do
    it "treats an existing file with a path-like name as text to extract from" do
      Tempfile.open("iriq-autofile") do |f|
        f.write("see https://foo.com.\nalso (https://bar.com).\n")
        f.flush
        expect(run(f.path)).to eq(0)
        out = stdout.string
        expect(out).to include("https://foo.com")
        expect(out).to include("https://bar.com")
      end
    end

    it "section flags apply to extracted IRIs from a file arg" do
      Tempfile.open("iriq-autofile") do |f|
        f.write("see https://foo.com/users/1 and https://foo.com/users/2.")
        f.flush
        expect(run("-n", f.path)).to eq(0)
        expect(stdout.string.lines.map(&:chomp)).to eq([
          "https://foo.com/users/{user_id}",
          "https://foo.com/users/{user_id}",
        ])
      end
    end

    it "feeds auto-detected file into --corpus" do
      corpus_file = Tempfile.new(["iriq-autocorpus", ".json"])
      corpus_file.close
      File.delete(corpus_file.path)

      Tempfile.open("iriq-autofile") do |f|
        f.write("see https://foo.com/users/1 and https://foo.com/users/2")
        f.flush
        expect(run("--corpus", corpus_file.path, f.path)).to eq(0)
      end

      data = JSON.parse(File.read(corpus_file.path))
      expect(data["host_counts"]).to eq("foo.com" => 2)
      corpus_file.close!  # explicit cleanup; keeps the ref alive through the assertions
    end

    it "leaves URL-shaped args alone — they still go through summary mode" do
      expect(run("https://foo.com/users/1")).to eq(0)
      expect(stdout.string).to include("# parse")
      expect(stdout.string).to include("https://foo.com/users/1")
    end
  end

  describe "cluster" do
    it "clusters identifiers from stdin" do
      stdin.string = <<~LINES
        https://foo.com/users/1
        https://foo.com/users/2
        https://foo.com/posts/abc-123/edit
      LINES

      expect(run("cluster")).to eq(0)
      out = stdout.string
      expect(out).to include("[2] foo.com  /users/{user_id}")
      expect(out).to include("/posts/{post_id}/edit")
    end

    it "silently skips non-URL lines via the extractor" do
      stdin.string = "https://foo.com/users/1\nnot-a-url\nhttps://foo.com/users/2\n"

      expect(run("cluster")).to eq(0)
      expect(stderr.string).to be_empty
      expect(stdout.string).to include("[2] foo.com  /users/{user_id}")
    end

    it "reads from a file when given a path" do
      Tempfile.open("iriq-cli") do |f|
        f.puts "https://foo.com/x/1"
        f.puts "https://foo.com/x/2"
        f.flush

        expect(run("cluster", f.path)).to eq(0)
        expect(stdout.string).to include("[2] foo.com  /x/{x_id}")
      end
    end

    it "emits JSON with --json" do
      stdin.string = "https://foo.com/users/1\nhttps://foo.com/users/2\n"
      expect(run("cluster", "--json")).to eq(0)
      data = JSON.parse(stdout.string)
      expect(data.size).to eq(1)
      expect(data.first).to include(
        "shape" => "/users/{user_id}",
        "host"  => "foo.com",
        "count" => 2,
      )
    end
  end
end
