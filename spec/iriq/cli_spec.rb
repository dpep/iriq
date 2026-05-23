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

  describe "default (no section flag)" do
    it "runs parse + normalize + explain for a URL-ish input" do
      expect(run("foo.com/users/123")).to eq(0)
      out = stdout.string
      expect(out).to include("# parse")
      expect(out).to include("scheme:        https")
      expect(out).to include("host:          foo.com")
      expect(out).to include("# normalize")
      expect(out).to include("https://foo.com/users/{user_id}")
      expect(out).to include("# explain")
      expect(out).to match(/\* integer_id\s+user_id\s+123/)
    end

    it "emits a single combined JSON object with --json" do
      expect(run("--json", "https://foo.com/users/123")).to eq(0)
      data = JSON.parse(stdout.string)
      expect(data.keys).to contain_exactly("parse", "normalize", "explain")
      expect(data["parse"]).to include("host" => "foo.com")
      expect(data["normalize"]).to eq("https://foo.com/users/{user_id}")
      expect(data["explain"].last).to include("hint" => "user_id")
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
      expect(out).not_to include("# explain")
    end

    it "prints only the normalize section with -n" do
      expect(run("-n", "foo.com/users/123")).to eq(0)
      expect(stdout.string.strip).to eq("https://foo.com/users/{user_id}")
    end

    it "prints only the explain section with -e" do
      expect(run("-e", "https://foo.com/users/123")).to eq(0)
      out = stdout.string
      expect(out).to match(/\* integer_id\s+user_id\s+123/)
      expect(out).not_to include("# parse")
    end

    it "combines flags (-pe) and shows section headers" do
      expect(run("-pe", "https://foo.com/users/123")).to eq(0)
      out = stdout.string
      expect(out).to include("# parse")
      expect(out).to include("# explain")
      expect(out).not_to include("# normalize")
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
  end

  describe "--no-hints" do
    it "uses mechanical placeholders" do
      expect(run("-n", "--no-hints", "foo.com/users/123")).to eq(0)
      expect(stdout.string.strip).to eq("https://foo.com/users/{integer_id}")
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

    it "skips lines that fail to parse but keeps going" do
      stdin.string = "https://foo.com/users/1\nnot-a-url\nhttps://foo.com/users/2\n"

      expect(run("cluster")).to eq(0)
      expect(stderr.string).to include("skipped")
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
