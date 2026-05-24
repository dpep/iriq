require "json"
require "open3"
require "tempfile"

# End-to-end specs that shell out to the real `exe/iriq` binary. These catch
# issues the injected-IO CLI specs can't — missing requires, real stdin TTY
# detection, multi-invocation persistence, etc. Slower than the unit specs.
describe "iriq CLI (end-to-end)" do
  ROOT = File.expand_path("../../..", __FILE__)
  EXE  = File.join(ROOT, "exe", "iriq")

  def iriq(*args, stdin: nil)
    cmd = ["bundle", "exec", EXE, *args]
    Open3.capture3({ "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile") }, *cmd, stdin_data: stdin || "")
  end

  it "prints the version" do
    out, err, status = iriq("--version")
    expect(status.exitstatus).to eq(0)
    expect(out.strip).to eq(Iriq::VERSION)
    expect(err).to be_empty
  end

  it "summarizes a single input" do
    out, _err, status = iriq("https://foo.com/users/123")
    expect(status.exitstatus).to eq(0)
    expect(out).to include("# parse")
    expect(out).to include("# normalize")
    expect(out).to include("https://foo.com/users/{user_id}")
  end

  it "processes piped stdin → URL list with counts" do
    input = "https://foo.com/users/1\nhttps://foo.com/users/1\nhttps://foo.com/users/2\n"
    out, _err, status = iriq(stdin: input)
    expect(status.exitstatus).to eq(0)
    expect(out).to include("[2] https://foo.com/users/1")
    expect(out).to include("[1] https://foo.com/users/2")
  end

  it "the cluster keyword still produces cluster output" do
    input = "https://foo.com/users/1\nhttps://foo.com/users/2\n"
    out, _err, status = iriq("cluster", stdin: input)
    expect(status.exitstatus).to eq(0)
    expect(out).to include("[2] foo.com  /users/{user_id}")
  end

  it "prints --stats from piped input" do
    input = "https://foo.com/users/1\nhttps://bar.com/x\n"
    out, _err, status = iriq("--stats", stdin: input)
    expect(status.exitstatus).to eq(0)
    expect(out).to include("observations: 2")
    expect(out).to match(/1\s+foo\.com/)
    expect(out).to match(/1\s+bar\.com/)
  end

  describe "corpus persistence across invocations" do
    let(:corpus_path) do
      f = Tempfile.new(["iriq-e2e", ".json"])
      f.close
      File.delete(f.path)
      f.path
    end
    after { File.delete(corpus_path) if File.exist?(corpus_path) }

    it "creates, accumulates, and persists corpus state" do
      # First invocation: create
      _, _, s1 = iriq("--corpus", corpus_path, "https://foo.com/users/1")
      expect(s1.exitstatus).to eq(0)
      expect(File.exist?(corpus_path)).to be true

      # Second invocation: load + observe
      _, _, s2 = iriq("--corpus", corpus_path, "https://foo.com/users/2")
      expect(s2.exitstatus).to eq(0)

      # Third: read stats (--stats with no positional doesn't observe)
      out, _, s3 = iriq("--corpus", corpus_path, "--stats", "--json")
      expect(s3.exitstatus).to eq(0)
      data = JSON.parse(out)
      expect(data["hosts"]).to eq("foo.com" => 2)
      expect(data["observations"]).to eq(2)
    end

    it "promotes high-cardinality literal positions in corpus-informed normalize" do
      # Seed in one batch invocation (via stdin) rather than N separate
      # processes — far less surface for flakes, no save/load roundtrip
      # between each observation. We use a comfortable safety margin
      # (20 distinct names) so the heuristic clears the cardinality
      # thresholds even if one or two obs were somehow lost.
      names = %w[
        alice bob carol dave erin frank gina hank ivan jane
        kara liam mira nina olga peter quinn riley sam tina
      ]
      seed = names.map { |n| "https://foo.com/users/#{n}/profile" }.join("\n")
      _, _, st = iriq("--corpus", corpus_path, stdin: seed)
      expect(st.exitstatus).to eq(0)

      out, _, st = iriq("-n", "--corpus", corpus_path, "https://foo.com/users/zoe/profile")
      expect(st.exitstatus).to eq(0)
      expect(out.strip).to eq("https://foo.com/users/{user}/profile")
    end

    it "ingests batch from stdin into the persistent corpus" do
      input = (1..5).map { |i| "https://foo.com/users/#{i}" }.join("\n") + "\n"
      _, _, st = iriq("--corpus", corpus_path, stdin: input)
      expect(st.exitstatus).to eq(0)

      out, _, _ = iriq("--corpus", corpus_path, "--stats", "--json")
      expect(JSON.parse(out)["observations"]).to eq(5)
    end
  end

  it "returns exit 2 with a parse-error message for junk input" do
    _, err, status = iriq("just-some-token")
    expect(status.exitstatus).to eq(2)
    expect(err).to include("parse error")
  end

  describe "IriGenerator stream → CLI" do
    let(:corpus_path) do
      f = Tempfile.new(["iriq-e2e-gen", ".json"])
      f.close
      File.delete(f.path)
      f.path
    end
    after { File.delete(corpus_path) if File.exist?(corpus_path) }

    let(:url_stream) { IriGenerator.urls(count: 3000, seed: 1234).join("\n") + "\n" }

    it "ingests a 3k-URL stream and produces stable stats" do
      out, _err, st = iriq("--corpus", corpus_path, "--stats", "--json", stdin: url_stream)
      expect(st.exitstatus).to eq(0)

      data = JSON.parse(out)
      expect(data["observations"]).to eq(3000)
      expect(data["hosts"].keys).to contain_exactly(*IriGenerator::HOSTS)
      expect(data["shapes"]).to include("/users/{user_id}", "/sessions/{session_uuid}")
    end

    it "persists the corpus across invocations (re-reads identical stats)" do
      out1, _, _ = iriq("--corpus", corpus_path, "--stats", "--json", stdin: url_stream)
      out2, _, _ = iriq("--corpus", corpus_path, "--stats", "--json")
      expect(JSON.parse(out2)).to eq(JSON.parse(out1))
    end

    it "corpus-informed normalize learns workspace patterns from the stream" do
      _, _, st = iriq("--corpus", corpus_path, stdin: url_stream)
      expect(st.exitstatus).to eq(0)

      # Popular workspace stays literal
      pop, _, _ = iriq("-n", "--corpus", corpus_path, "https://app.example.com/workspaces/primary")
      expect(pop.strip).to eq("https://app.example.com/workspaces/primary")

      # One-shot vocab word gets promoted to {workspace}
      one, _, _ = iriq("-n", "--corpus", corpus_path, "https://app.example.com/workspaces/sigma")
      expect(one.strip).to eq("https://app.example.com/workspaces/{workspace}")
    end
  end
end
