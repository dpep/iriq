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

  describe "help / usage" do
    it "prints usage with no args" do
      expect(run).to eq(0)
      expect(stdout.string).to include("Usage: iriq")
    end

    it "prints usage on --help" do
      expect(run("--help")).to eq(0)
      expect(stdout.string).to include("Usage: iriq")
    end

    it "prints usage on `help`" do
      expect(run("help")).to eq(0)
      expect(stdout.string).to include("Usage: iriq")
    end

    it "errors on unknown command" do
      expect(run("frobnicate")).to eq(1)
      expect(stderr.string).to include("unknown command")
    end
  end

  describe "version" do
    it "prints the version" do
      expect(run("version")).to eq(0)
      expect(stdout.string.strip).to eq(Iriq::VERSION)
    end
  end

  describe "parse" do
    it "prints structured fields" do
      expect(run("parse", "https://foo.com/users/123")).to eq(0)
      out = stdout.string
      expect(out).to include("scheme:        https")
      expect(out).to include("host:          foo.com")
      expect(out).to include('["users", "123"]')
      expect(out).to include("canonical:     https://foo.com/users/123")
    end

    it "emits JSON with --json" do
      expect(run("parse", "--json", "https://foo.com/users/123")).to eq(0)
      data = JSON.parse(stdout.string)
      expect(data).to include(
        "scheme"        => "https",
        "host"          => "foo.com",
        "path_segments" => ["users", "123"],
        "canonical"     => "https://foo.com/users/123",
      )
    end

    it "returns exit 2 with a parse error message" do
      expect(run("parse", "just-some-token")).to eq(2)
      expect(stderr.string).to include("parse error")
    end

    it "errors on missing argument" do
      expect(run("parse")).to eq(1)
      expect(stderr.string).to include("missing argument")
    end
  end

  describe "normalize" do
    it "prints the shape-normalized form" do
      expect(run("normalize", "https://foo.com/users/123")).to eq(0)
      expect(stdout.string.strip).to eq("https://foo.com/users/{integer_id}")
    end

    it "emits JSON with --json" do
      expect(run("normalize", "-j", "foo.com/users/1")).to eq(0)
      expect(JSON.parse(stdout.string)).to eq("normalized" => "https://foo.com/users/{integer_id}")
    end
  end

  describe "explain" do
    it "prints one row per segment" do
      expect(run("explain", "https://foo.com/users/123")).to eq(0)
      lines = stdout.string.lines.map(&:rstrip)
      expect(lines[0]).to match(/  literal\s+users/)
      expect(lines[1]).to match(/\* integer_id\s+123/)
    end

    it "emits JSON with --json" do
      expect(run("explain", "--json", "https://foo.com/users/123")).to eq(0)
      data = JSON.parse(stdout.string)
      expect(data).to eq([
        { "value" => "users", "type" => "literal",    "variable" => false },
        { "value" => "123",   "type" => "integer_id", "variable" => true  },
      ])
    end
  end

  describe "classify" do
    it "prints the classification" do
      expect(run("classify", "abc-123-def")).to eq(0)
      expect(stdout.string.strip).to eq("slug")
    end

    it "emits JSON with --json" do
      expect(run("classify", "--json", "123")).to eq(0)
      expect(JSON.parse(stdout.string)).to eq("value" => "123", "type" => "integer_id")
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
      expect(out).to include("[2] foo.com  /users/{integer_id}")
      expect(out).to include("/posts/{slug}/edit")
    end

    it "skips lines that fail to parse but keeps going" do
      stdin.string = "https://foo.com/users/1\nnot-a-url\nhttps://foo.com/users/2\n"

      expect(run("cluster")).to eq(0)
      expect(stderr.string).to include("skipped")
      expect(stdout.string).to include("[2] foo.com  /users/{integer_id}")
    end

    it "reads from a file when given a path" do
      Tempfile.open("iriq-cli") do |f|
        f.puts "https://foo.com/x/1"
        f.puts "https://foo.com/x/2"
        f.flush

        expect(run("cluster", f.path)).to eq(0)
        expect(stdout.string).to include("[2] foo.com  /x/{integer_id}")
      end
    end

    it "emits JSON with --json" do
      stdin.string = "https://foo.com/users/1\nhttps://foo.com/users/2\n"
      expect(run("cluster", "--json")).to eq(0)
      data = JSON.parse(stdout.string)
      expect(data.size).to eq(1)
      expect(data.first).to include(
        "shape" => "/users/{integer_id}",
        "host"  => "foo.com",
        "count" => 2,
      )
    end
  end
end
