describe "Recognizer proposals" do
  describe "Corpus#propose_recognizers" do
    let(:corpus) { Iriq::Corpus.new }

    it "returns an empty list when there's no signal" do
      expect(corpus.propose_recognizers).to eq([])
    end

    it "proposes a Recognizer when a prefix dominates at a slug/opaque_id position" do
      # 25 GitHub-PAT-shaped tokens at the same Position — well above the
      # 20-observation noise floor with full coverage.
      25.times do |i|
        corpus.observe("https://api.github.com/auth/ghp_aaaa#{i.to_s.rjust(4, '0')}xyzzy")
      end

      proposals = corpus.propose_recognizers

      expect(proposals.size).to eq(1)
      p = proposals.first
      expect(p.prefix).to            eq("ghp_")
      expect(p.suggested_type).to    eq(:ghp)
      expect(p.coverage).to          eq(1.0)
      expect(p.observation_count).to eq(25)
      expect(p.hosts).to             include("api.github.com")
      expect(p.sample_values.size).to be <= 5
      expect(p.strategy).to          eq(:prefix_underscore_id)
    end

    it "ignores prefixes that don't pass the coverage floor" do
      # 5 PAT-shaped, 25 plain slug values at the same position — slug
      # dominates, prefix coverage too low to fire.
      5.times  { |i| corpus.observe("https://foo.com/x/ghp_abcd#{i}efghijklmn") }
      25.times { |i| corpus.observe("https://foo.com/x/red-team-member-#{i}") }

      expect(corpus.propose_recognizers).to be_empty
    end

    it "ignores below the observation noise floor" do
      # Only 10 matching observations — below default 20.
      10.times { |i| corpus.observe("https://api.github.com/auth/ghp_ab#{i.to_s.rjust(4, '0')}cdwxyz") }
      expect(corpus.propose_recognizers).to be_empty
    end

    it "honors min_hosts to require cross-host evidence" do
      25.times { |i| corpus.observe("https://api.github.com/auth/ghp_abcd#{i.to_s.rjust(4, '0')}wxyz") }

      expect(corpus.propose_recognizers(min_hosts: 1).size).to eq(1)
      expect(corpus.propose_recognizers(min_hosts: 2)).to     be_empty
    end

    it "honors strategies: parameter — empty list disables all detection" do
      25.times { |i| corpus.observe("https://api.github.com/auth/ghp_ab#{i.to_s.rjust(4, '0')}cdwxyz") }
      expect(corpus.propose_recognizers(strategies: [])).to eq([])
    end

    it "doesn't propose for plain slugs (no `<prefix>_` shape)" do
      30.times { |i| corpus.observe("https://foo.com/posts/red-team-member-#{i}") }
      expect(corpus.propose_recognizers).to be_empty
    end
  end

  describe Iriq::RecognizerProposal do
    it "freezes its positions and sample_values for safe sharing" do
      pos = Iriq::Position.path(host: "foo.com", prefix: "/x")
      p = described_class.new(
        prefix: "ghp_", suggested_type: :ghp,
        positions: [pos], hosts: ["foo.com"],
        coverage: 1.0, observation_count: 25,
        sample_values: ["ghp_a", "ghp_b"],
        strategy: :prefix_underscore_id,
      )
      expect(p.positions).to be_frozen
      expect(p.sample_values).to be_frozen
      expect(p.hosts).to be_frozen
    end

    it "round-trips to a Hash" do
      pos = Iriq::Position.path(host: "foo.com", prefix: "/x")
      p = described_class.new(
        prefix: "ghp_", suggested_type: :ghp,
        positions: [pos], hosts: ["foo.com"],
        coverage: 0.95, observation_count: 100,
        sample_values: ["ghp_a"],
        strategy: :prefix_underscore_id,
      )
      h = p.to_h
      expect(h[:prefix]).to            eq("ghp_")
      expect(h[:suggested_type]).to    eq(:ghp)
      expect(h[:hosts]).to             eq(["foo.com"])
      expect(h[:coverage]).to          eq(0.95)
      expect(h[:positions].first[:locator]).to eq("/x")
    end
  end
end
