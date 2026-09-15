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

    it "rebuilds numeric ranges from finite values only on reopen" do
      sqlite = Iriq::Corpus.open(@path)
      ["1" * 400, "3", "5"].each { |v| sqlite.observe("https://foo.com/p?v=#{v}") }
      sqlite.close

      reopened = Iriq::Corpus.open(@path)
      row = reopened.clusters.first.param_summary.find { |r| r[:name] == "v" }
      expect(row.values_at(:min, :max, :avg)).to eq([3.0, 5.0, 4.0])
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

    it "dedupes cluster examples by canonical" do
      sqlite = Iriq::Corpus.open(@path)
      3.times { sqlite.observe("https://foo.com/users/1") }
      sqlite.observe("https://foo.com/users/2")

      cluster = sqlite.clusters.first
      expect(cluster.count).to eq(4)
      expect(cluster.examples.map(&:canonical))
        .to eq(%w[https://foo.com/users/1 https://foo.com/users/2])
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

    describe "query-param persistence" do
      let(:param_inputs) do
        (1..10).map { |i| "https://foo.com/search?page=#{i}&format=json" }
      end

      it "matches the Memory backend's param summary" do
        mem    = Iriq::Corpus.new
        sqlite = Iriq::Corpus.open(@path)
        observe_through(mem, param_inputs)
        observe_through(sqlite, param_inputs)

        expect(sqlite.clusters.first.param_summary).to eq(mem.clusters.first.param_summary)
        sqlite.close
      end

      it "survives a close-and-reopen round-trip" do
        sqlite = Iriq::Corpus.open(@path)
        observe_through(sqlite, param_inputs)
        before = sqlite.clusters.first.param_summary
        sqlite.close

        reopened = Iriq::Corpus.open(@path)
        after = reopened.clusters.first.param_summary
        expect(after).to eq(before)

        page = after.find { |row| row[:name] == "page" }
        expect(page).to include(type: :integer, count: 10, min: 1.0, max: 10.0)
        reopened.close
      end

      it "caps tracked param values while counting every observation" do
        sqlite = Iriq::Corpus.open(@path, max_values_per_position: 5)
        20.times { |i| sqlite.observe("https://foo.com/items?page=#{i}") }

        stats = sqlite.clusters.first.param_stats["page"]
        expect(stats.cardinality).to eq(5)
        expect(stats.total).to eq(20)
        sqlite.close
      end
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

  describe "narrow reads" do
    around do |example|
      Dir.mktmpdir("iriq-narrow") do |dir|
        @dir = dir
        example.run
      end
    end

    let(:huge) { "1" * 400 }

    # A cap of 3 so each position and param drops a value.
    def each_backend
      {
        "memory" => Iriq::Storage::Memory.new(max_values_per_position: 3),
        "json"   => Iriq::Storage.open(File.join(@dir, "c.json"), max_values_per_position: 3),
        "sqlite" => Iriq::Storage.open(File.join(@dir, "c.db"), max_values_per_position: 3),
      }.each do |name, storage|
        yield name, storage
      ensure
        storage.close
      end
    end

    it "agree with the full reads they replace, on every backend" do
      position = Iriq::Position.path(host: "x.com", prefix: "/teams")
      unseen   = Iriq::Position.path(host: "x.com", prefix: "/nowhere")

      each_backend do |backend, storage|
        [[huge, :integer], ["a", :literal], ["7", :integer], ["a", :literal], ["b-c", :slug], ["7", :integer]]
          .each { |value, type| storage.observe_position(position, value, type) }
        ["https://x.com/teams/a?page=#{huge}&tab=a", "https://x.com/teams/a?page=1&tab=b",
         "https://x.com/teams/b?page=2&tab=c", "https://x.com/teams/c?page=2&tab=d",
         "https://x.com/teams/d?page=7&tab=a"]
          .each { |url| storage.add_to_cluster("k", "x.com", "https", "/teams/{team}", Iriq.parse(url)) }

        [position, unseen].each do |pos|
          stats = storage.position_stats(pos)
          # Tracked (including the 400-digit value), dropped at the cap, never seen.
          [huge, "a", "7", "b-c", "zzz"].each do |value|
            expect(storage.position_evidence(pos, value))
              .to eq(stats && Iriq::PositionEvidence.from_stats(stats, value)), "#{backend}: #{value[0, 8]} at #{pos.locator}"
          end
        end

        [%w[k page], %w[k tab], %w[k nope], %w[nope page]].each do |key, name|
          full = storage.cluster_for(key)&.param_stats&.[](name)
          expect(storage.param_stats(key, name)&.dump).to eq(full&.dump), "#{backend}: #{key} #{name}"
        end
      end
    end
  end

  describe "files iriq refuses to open" do
    around do |example|
      Dir.mktmpdir("iriq-refuse") do |dir|
        @dir = dir
        example.run
      end
    end

    it "refuses a JSON object with none of the corpus keys and leaves it untouched" do
      path = File.join(@dir, "notes.json")
      File.write(path, %({"foo": 1}))
      expect { Iriq::Corpus.open(path) }
        .to raise_error(Iriq::CorpusError, "corpus #{path}: not an iriq corpus (no corpus keys at the top level)")
      expect(File.read(path)).to eq(%({"foo": 1}))
    end

    it "refuses JSON that isn't an object, and malformed JSON" do
      list = File.join(@dir, "list.json")
      File.write(list, "[1, 2]")
      expect { Iriq::Corpus.open(list) }
        .to raise_error(Iriq::CorpusError, "corpus #{list}: not an iriq corpus (no corpus keys at the top level)")

      broken = File.join(@dir, "broken.json")
      File.write(broken, %({"host_counts": ))
      expect { Iriq::Corpus.open(broken) }.to raise_error(Iriq::CorpusError, "corpus #{broken}: not valid JSON")
    end

    it "reports a SQLite file it can't open as a CorpusError, not a SQLite exception" do
      garbage = File.join(@dir, "garbage.db")
      File.write(garbage, "not a sqlite database " * 20)
      expect { Iriq::Corpus.open(garbage) }
        .to raise_error(Iriq::CorpusError, "corpus #{garbage}: file is not a database")

      directory = File.join(@dir, "dir.db")
      Dir.mkdir(directory)
      expect { Iriq::Corpus.open(directory) }
        .to raise_error(Iriq::CorpusError, "corpus #{directory}: unable to open database file")
    end

    it "reports a JSON corpus it can't read or write as a CorpusError, in the OS's words" do
      directory = File.join(@dir, "dir.json")
      Dir.mkdir(directory)
      expect { Iriq::Corpus.open(directory) }
        .to raise_error(Iriq::CorpusError, "corpus #{directory}: Is a directory (os error 21)")

      unwritable = File.join(@dir, "missing", "c.json")
      corpus = Iriq::Corpus.open(unwritable)
      corpus.observe("https://foo.com/x")
      expect { corpus.save }
        .to raise_error(Iriq::CorpusError, "corpus #{unwritable}: No such file or directory (os error 2)")
    end

    it "treats {} as an empty corpus" do
      path = File.join(@dir, "empty.json")
      File.write(path, "{}")
      corpus = Iriq::Corpus.open(path)
      corpus.observe("https://foo.com/x")
      corpus.save
      expect(JSON.parse(File.read(path))["host_counts"]).to eq("foo.com" => 1)
    end

    it "refuses a SQLite corpus from a newer schema without modifying it" do
      require "iriq/storage/sqlite"
      path = File.join(@dir, "future.db")
      db = SQLite3::Database.new(path)
      db.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
      db.execute("INSERT INTO meta VALUES ('schema_version', '99')")
      db.close

      expect { Iriq::Corpus.open(path) }.to raise_error(
        Iriq::CorpusError,
        "corpus #{path}: schema version 99 is newer than this iriq supports (#{Iriq::Storage::Sqlite::SCHEMA_VERSION}); upgrade iriq",
      )
      db = SQLite3::Database.new(path)
      expect(db.execute("SELECT name FROM sqlite_master WHERE type = 'table'").flatten).to eq(["meta"])
      db.close
    end
  end

  describe "JSON saves" do
    around do |example|
      Dir.mktmpdir("iriq-json-save") do |dir|
        @dir = dir
        example.run
      end
    end

    it "don't depend on a fixed PATH.tmp name" do
      path = File.join(@dir, "c.json")
      Dir.mkdir("#{path}.tmp") # something already occupying the old shared name
      corpus = Iriq::Corpus.open(path)
      corpus.observe("https://foo.com/x")
      corpus.save
      corpus.save(File.join(@dir, "export.json"))

      expect(JSON.parse(File.read(path))["host_counts"]).to eq("foo.com" => 1)
      expect(Dir.children(@dir)).to contain_exactly("c.json", "c.json.tmp", "export.json")
    end

    it "write through PATH.<pid>.<n>.tmp, the name --reset sweeps" do
      path = File.join(@dir, "c.json")
      temps = []
      allow(File).to receive(:rename).and_wrap_original { |orig, from, to| temps << from; orig.call(from, to) }
      corpus = Iriq::Corpus.open(path)
      2.times { corpus.save }

      expect(temps).to all(match(/\A#{Regexp.escape(path)}\.#{Process.pid}\.\d+\.tmp\z/))
      expect(temps.uniq.size).to eq(2)
    end

    it "survive concurrent writers (last writer wins, nobody crashes)" do
      path = File.join(@dir, "shared.json")
      writers = 4.times.map do |w|
        Thread.new do
          corpus = Iriq::Corpus.open(path)
          corpus.observe("https://w#{w}.com/x")
          20.times { corpus.save }
        end
      end
      expect { writers.each(&:join) }.not_to raise_error
      expect(JSON.parse(File.read(path))["host_counts"].size).to eq(1)
    end
  end
end
