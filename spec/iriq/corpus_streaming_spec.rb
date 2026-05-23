describe "Iriq::Corpus on a realistic stream" do
  subject(:corpus) { Iriq::Corpus.new }

  let(:urls) { IriqStreamingFixtures.urls(count: 1000, seed: 1234) }

  before do
    urls.each { |u| corpus.observe(u) }
  end

  describe "ingestion + aggregates" do
    it "ingests all observations" do
      expect(corpus.host_counts.values.sum).to eq(1000)
    end

    it "covers all three fixture hosts" do
      expect(corpus.host_counts.keys).to contain_exactly(*IriqStreamingFixtures::HOSTS)
    end

    it "stats counters are consistent with observation count" do
      expect(corpus.path_length_counts.values.sum).to eq(1000)
      expect(corpus.fingerprint_counts.values.sum).to eq(1000)
    end
  end

  describe "deterministic clustering (mechanical fingerprints)" do
    it "collapses RESTful integer/uuid positions" do
      shapes = corpus.fingerprint_counts.keys
      expect(shapes).to include(
        "/users/{user_id}",
        "/users/{user_id}/orders/{order_id}",
        "/sessions/{session_uuid}",
      )
    end

    it "does NOT collapse the org slug position (mechanical can't see across observations)" do
      # /orgs/<slug>/... stays per-slug at this stage — that's what
      # corpus.normalize is for, see below.
      org_shapes = corpus.fingerprint_counts.keys.grep(%r(\A/orgs/[^{]))
      expect(org_shapes.size).to be > 1
    end

    it "preserves /users/me as its own cluster (one per host)" do
      me_clusters = corpus.clusters.select { |c| c.shape == "/users/me" }
      expect(me_clusters.size).to eq(IriqStreamingFixtures::HOSTS.size)
      expect(me_clusters.map(&:count).sum).to be > 0
    end
  end

  describe "corpus-informed normalize" do
    it "uses mechanical placeholders for already-variable positions" do
      out = corpus.normalize("https://app.example.com/users/1042")
      expect(out).to eq("https://app.example.com/users/{user_id}")
    end

    it "leaves a small stable enum (8 org slugs repeated ~30x each) alone" do
      # 8 distinct slugs with heavy repetition look like a fixed enum, not a
      # variable slot. corpus.normalize should preserve the literal.
      out = corpus.normalize("https://api.example.com/orgs/gusto/users/1042")
      expect(out).to eq("https://api.example.com/orgs/gusto/users/{user_id}")
    end

    it "promotes a high-singleton-cardinality literal position to a placeholder" do
      # Fresh corpus seeded with many one-shot literal handles — that's
      # exactly what corpus_inferred_variable is designed to catch.
      fresh = Iriq::Corpus.new
      %w[fooname barname bazname quxname corgename grault waldo plugh xyzzy thud spam ham eggs].each do |n|
        fresh.observe("https://api.example.com/orgs/#{n}/users/1")
      end
      out = fresh.normalize("https://api.example.com/orgs/newname/users/1")
      expect(out).to eq("https://api.example.com/orgs/{org}/users/{user_id}")
    end
  end

  describe "explainability" do
    it "marks /users/me as a rare_literal under a mostly-variable /users/ position" do
      rows = corpus.explain("https://app.example.com/users/me")
      expect(rows.last[:classification]).to eq(:rare_literal)
    end

    it "marks an unseen literal at a variable-dominated position as :ambiguous" do
      # `somebody` (no dash) classifies as :literal — would be :slug with a dash.
      rows = corpus.explain("https://app.example.com/users/somebody")
      expect(rows.last[:classification]).to eq(:ambiguous)
    end

    it "marks a literal at a high-cardinality literal position as :corpus_inferred_variable" do
      fresh = Iriq::Corpus.new
      %w[fooname barname bazname quxname corgename grault waldo plugh xyzzy thud spam ham eggs].each do |n|
        fresh.observe("https://api.example.com/orgs/#{n}/users/1")
      end
      rows = fresh.explain("https://api.example.com/orgs/fooname/users/1")
      expect(rows[1][:classification]).to eq(:corpus_inferred_variable)
    end
  end

  describe "long tail" do
    it "the /weird routes don't dominate the cluster list" do
      weird = corpus.clusters.count { |c| c.shape.start_with?("/weird/") }
      total = corpus.clusters.size
      expect(weird.to_f / total).to be < 0.5
    end
  end
end
