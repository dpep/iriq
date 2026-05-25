require "tempfile"

describe Iriq::Storage do
  describe ".open" do
    it "returns a Memory backend when path is nil" do
      expect(described_class.open(nil)).to be_a(Iriq::Storage::Memory)
    end

    it "picks Json by default extension" do
      Tempfile.create(["corpus", ".json"]) do |f|
        expect(described_class.open(f.path)).to be_a(Iriq::Storage::Json)
      end
    end

    it "picks Sqlite for .db / .sqlite / .sqlite3" do
      %w[.db .sqlite .sqlite3].each do |ext|
        Tempfile.create(["corpus", ext]) do |f|
          f.close
          File.delete(f.path)
          storage = described_class.open(f.path)
          expect(storage).to be_a(Iriq::Storage::Sqlite)
          storage.close
        end
      end
    end
  end

  describe "Sqlite backend parity with Memory" do
    let(:inputs) do
      %w[
        https://foo.com/users/1
        https://foo.com/users/2
        https://foo.com/users/3
        https://foo.com/posts/abc-123/edit
        https://bar.com/x
        urn:isbn:0451450523
      ]
    end

    around do |example|
      Tempfile.create(["iriq-corpus", ".db"]) do |f|
        @path = f.path
        f.close
        File.delete(@path)
        example.run
      end
    end

    def observe_through(corpus, urls)
      urls.each { |u| corpus.observe(u) }
    end

    it "produces identical aggregates to the in-memory corpus" do
      mem    = Iriq::Corpus.new
      sqlite = Iriq::Corpus.open(@path)

      observe_through(mem, inputs)
      observe_through(sqlite, inputs)

      expect(sqlite.host_counts).to eq(mem.host_counts)
      expect(sqlite.path_length_counts).to eq(mem.path_length_counts)
      expect(sqlite.raw_shape_counts).to eq(mem.raw_shape_counts)
      expect(sqlite.fingerprint_counts).to eq(mem.fingerprint_counts)
      expect(sqlite.size).to eq(mem.size)

      sqlite.close
    end

    it "produces identical position stats" do
      mem    = Iriq::Corpus.new
      sqlite = Iriq::Corpus.open(@path)
      observe_through(mem, inputs)
      observe_through(sqlite, inputs)

      mem_stats    = mem.stats_for("foo.com", "/users")
      sqlite_stats = sqlite.stats_for("foo.com", "/users")

      expect(sqlite_stats.total).to eq(mem_stats.total)
      expect(sqlite_stats.value_counts).to eq(mem_stats.value_counts)
      expect(sqlite_stats.type_counts).to eq(mem_stats.type_counts)

      sqlite.close
    end

    it "produces identical normalize output for corpus-informed queries" do
      mem    = Iriq::Corpus.new
      sqlite = Iriq::Corpus.open(@path)

      names = %w[alice bob carol dave erin frank gina hank ivan jane]
      names.each do |n|
        mem.observe("https://foo.com/users/#{n}/profile")
        sqlite.observe("https://foo.com/users/#{n}/profile")
      end

      expect(sqlite.normalize("https://foo.com/users/zoe/profile"))
        .to eq(mem.normalize("https://foo.com/users/zoe/profile"))
      expect(sqlite.normalize("https://foo.com/users/zoe/profile"))
        .to eq("https://foo.com/users/{user}/profile")

      sqlite.close
    end

    it "persists incrementally across reopens" do
      sqlite = Iriq::Corpus.open(@path)
      sqlite.observe("https://foo.com/users/1")
      sqlite.close

      reopened = Iriq::Corpus.open(@path)
      reopened.observe("https://foo.com/users/2")
      expect(reopened.host_counts["foo.com"]).to eq(2)
      expect(reopened.stats_for("foo.com", "/users").total).to eq(2)
      reopened.close
    end

    it "enforces the value cardinality cap" do
      sqlite = Iriq::Corpus.open(@path, max_values_per_position: 5)
      20.times { |i| sqlite.observe("https://foo.com/items/#{i}") }
      stats = sqlite.stats_for("foo.com", "/items")
      expect(stats.cardinality).to eq(5)
      expect(stats.total).to eq(20)
      sqlite.close
    end

    it "caps cluster examples at MAX_EXAMPLES" do
      sqlite = Iriq::Corpus.open(@path)
      30.times { |i| sqlite.observe("https://foo.com/users/#{i}") }
      cluster = sqlite.clusters.first
      expect(cluster.count).to eq(30)
      expect(cluster.examples.size).to eq(Iriq::Cluster::MAX_EXAMPLES)
      sqlite.close
    end

    it "exports to JSON via Corpus#save(path)" do
      sqlite = Iriq::Corpus.open(@path)
      sqlite.observe("https://foo.com/users/1")
      sqlite.observe("https://foo.com/users/2")

      Tempfile.create(["export", ".json"]) do |f|
        sqlite.save(f.path)
        json = JSON.parse(File.read(f.path))
        expect(json["host_counts"]).to eq("foo.com" => 2)
      end
      sqlite.close
    end

    it "survives concurrent observers via WAL" do
      writer1 = Iriq::Corpus.open(@path)
      writer2 = Iriq::Corpus.open(@path)

      writer1.observe("https://foo.com/users/1")
      writer2.observe("https://foo.com/users/2")
      writer1.observe("https://foo.com/users/3")

      writer1.close
      writer2.close

      reader = Iriq::Corpus.open(@path)
      expect(reader.host_counts["foo.com"]).to eq(3)
      expect(reader.stats_for("foo.com", "/users").total).to eq(3)
      reader.close
    end
  end
end
