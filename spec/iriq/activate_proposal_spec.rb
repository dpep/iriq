require "tmpdir"

describe "Recognizer auto-activation" do
  let(:corpus) { Iriq::Corpus.new }

  def observe_pat_stream(n: 25, host: "api.github.com")
    n.times do |i|
      corpus.observe("https://#{host}/auth/ghp_aaaa#{i.to_s.rjust(4, '0')}xyzzy")
    end
  end

  describe "Corpus#activate_proposal" do
    it "registers a SynthesizedRecognizer on a per-corpus classifier" do
      observe_pat_stream
      proposal = corpus.propose_recognizers.first

      recognizer = corpus.activate_proposal(proposal)

      expect(recognizer).to be_a(Iriq::SynthesizedRecognizer)
      expect(recognizer.prefix).to eq("ghp_")
      expect(corpus.classifier.recognizers.last).to eq(recognizer)
    end

    it "doesn't leak activation into the module-level DEFAULT classifier" do
      observe_pat_stream
      proposal = corpus.propose_recognizers.first
      corpus.activate_proposal(proposal)

      # Fresh corpus on DEFAULT shouldn't see the activated recognizer.
      other = Iriq::Corpus.new
      expect(other.classifier.recognizers.map(&:class)).not_to include(Iriq::SynthesizedRecognizer)
    end

    it "after activation, classify returns the new type for matching values" do
      observe_pat_stream
      corpus.activate_proposal(corpus.propose_recognizers.first)

      expect(corpus.classifier.classify("ghp_abcdef123")).to eq(:ghp)
    end

    it "reinfers existing observations through the new Recognizer" do
      observe_pat_stream
      # Before activation, the position dominantly typed as :slug.
      stats_before = corpus.stats_for("api.github.com", "/auth")
      expect(stats_before.type_counts.keys).to include(:slug)
      expect(stats_before.type_counts).not_to have_key(:ghp)

      corpus.activate_proposal(corpus.propose_recognizers.first)

      stats_after = corpus.stats_for("api.github.com", "/auth")
      expect(stats_after.type_counts).to have_key(:ghp)
      expect(stats_after.type_counts[:ghp]).to be > 0
    end

    it "persists the activation across SQLite reopens" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "corpus.db")

        c1 = Iriq::Corpus.open(path)
        25.times { |i| c1.observe("https://api.github.com/auth/ghp_aaaa#{i.to_s.rjust(4, '0')}xyzzy") }
        c1.activate_proposal(c1.propose_recognizers.first)
        c1.close

        c2 = Iriq::Corpus.open(path)
        expect(c2.activated_recognizer_count).to eq(1)
        expect(c2.classifier.recognizers.map { |r| r.respond_to?(:prefix) ? r.prefix : nil }).to include("ghp_")
        expect(c2.classifier.classify("ghp_xyzzy123")).to eq(:ghp)
        c2.close
      end
    end
  end

  describe "Corpus#activate_proposals_above" do
    it "activates only proposals at or above the coverage threshold" do
      observe_pat_stream
      activated = corpus.activate_proposals_above(0.5)
      expect(activated.size).to eq(1)
      expect(activated.first.prefix).to eq("ghp_")
    end

    it "no-op when no proposal clears the threshold" do
      observe_pat_stream
      # 1.5 is unreachable; coverage maxes at 1.0
      expect(corpus.activate_proposals_above(1.5)).to be_empty
    end
  end
end
