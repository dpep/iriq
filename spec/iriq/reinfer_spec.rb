require "tmpdir"

describe "re-runnable inference" do
  describe "Corpus#observed_iri_count" do
    it "increments with each observation" do
      corpus = Iriq::Corpus.new
      expect(corpus.observed_iri_count).to eq(0)
      corpus.observe("https://foo.com/users/1")
      corpus.observe("https://foo.com/users/2")
      expect(corpus.observed_iri_count).to eq(2)
    end
  end

  describe "Corpus#reinfer" do
    it "rebuilds materialized views from the source-IRI log" do
      corpus = Iriq::Corpus.new
      corpus.observe("https://foo.com/users/1")
      corpus.observe("https://foo.com/users/2")
      corpus.observe("https://foo.com/users/3")

      original_count = corpus.size
      original_host  = corpus.host_counts["foo.com"]
      original_stats = corpus.stats_for("foo.com", "/users")&.total

      corpus.reinfer

      expect(corpus.size).to eq(original_count)
      expect(corpus.host_counts["foo.com"]).to eq(original_host)
      expect(corpus.stats_for("foo.com", "/users")&.total).to eq(original_stats)
      expect(corpus.observed_iri_count).to eq(3)
    end

    it "is idempotent — repeated reinfer yields the same views" do
      corpus = Iriq::Corpus.new
      corpus.observe("https://foo.com/users/1")
      corpus.observe("https://foo.com/users/2")

      corpus.reinfer
      first = corpus.host_counts["foo.com"]
      corpus.reinfer
      expect(corpus.host_counts["foo.com"]).to eq(first)
    end

    it "picks up new classifier behavior on replay" do
      # Build a corpus, then swap the classifier for a stub that classifies
      # everything as :literal. Reinfer should produce a corpus whose
      # position stats reflect the new classifier output.
      corpus = Iriq::Corpus.new
      corpus.observe("https://foo.com/items/abc")
      corpus.observe("https://foo.com/items/def")

      stub = Class.new(Iriq::SegmentClassifier) do
        def classify(_value) = :literal
      end.new
      retuned = Iriq::Corpus.new(classifier: stub, storage: corpus.storage)
      retuned.reinfer

      stats = retuned.stats_for("foo.com", "/items")
      expect(stats.type_counts.keys).to eq([:literal])
    end
  end

  describe "SQLite-backed reinfer" do
    around do |example|
      Dir.mktmpdir do |dir|
        @path = File.join(dir, "corpus.db")
        example.run
      end
    end

    it "persists the log across opens and replays it" do
      corpus = Iriq::Corpus.open(@path)
      corpus.observe("https://foo.com/users/1")
      corpus.observe("https://foo.com/users/2")
      corpus.close

      reopened = Iriq::Corpus.open(@path)
      expect(reopened.observed_iri_count).to eq(2)

      reopened.reinfer
      expect(reopened.host_counts["foo.com"]).to eq(2)
      expect(reopened.size).to eq(1)
      reopened.close
    end

    # A transaction that reads before it writes can't take the write lock
    # once another process has committed (SQLite reports busy without
    # waiting), so reinfer must hold the lock from its first statement.
    it "waits for a writer that tries to commit mid-replay instead of failing" do
      skip "fork not supported on this platform" unless Process.respond_to?(:fork)
      seed = Iriq::Corpus.open(@path)
      3.times { |i| seed.observe("https://foo.com/users/#{i}") }
      seed.close

      corpus = Iriq::Corpus.open(@path)
      writer = nil
      allow(corpus.storage).to receive(:each_observed_iri).and_wrap_original do |original, &block|
        original.call(&block)
        writer = fork do
          other = Iriq::Corpus.open(@path)
          other.observe("https://foo.com/users/99")
          other.close
          exit!(0)
        rescue Exception # rubocop:disable Lint/RescueException
          exit!(1)
        end
        # Give the writer time to commit, if nothing holds the write lock.
        deadline = Time.now + 1
        sleep 0.02 until Time.now > deadline || Process.wait(writer, Process::WNOHANG)
      end

      expect { corpus.reinfer }.not_to raise_error
      Process.wait(writer) rescue Errno::ECHILD
      corpus.close

      reopened = Iriq::Corpus.open(@path)
      expect(reopened.observed_iri_count).to eq(4)
      expect(reopened.host_counts["foo.com"]).to eq(4)
      reopened.close
    end
  end
end
