describe "Iriq::Corpus on a realistic stream" do
  subject(:corpus) { Iriq::Corpus.new }

  let(:urls) { IriGenerator.urls(count: 3000, seed: 1234) }

  before { urls.each { |u| corpus.observe(u) } }

  describe "ingestion + aggregates" do
    it "ingests all observations" do
      expect(corpus.host_counts.values.sum).to eq(3000)
    end

    it "covers all three fixture hosts" do
      expect(corpus.host_counts.keys).to contain_exactly(*IriGenerator::HOSTS)
    end

    it "stats counters are consistent with observation count" do
      expect(corpus.path_length_counts.values.sum).to eq(3000)
      expect(corpus.fingerprint_counts.values.sum).to eq(3000)
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
      org_shapes = corpus.fingerprint_counts.keys.grep(%r(\A/orgs/[^{]))
      expect(org_shapes.size).to be > 1
    end
  end

  describe "corpus-informed normalize" do
    it "uses mechanical placeholders for already-variable positions" do
      out = corpus.normalize("https://app.example.com/users/1042")
      expect(out).to eq("https://app.example.com/users/{user_id}")
    end

    it "leaves a small stable enum (8 org slugs repeated heavily) alone" do
      out = corpus.normalize("https://api.example.com/orgs/gusto/users/1042")
      expect(out).to eq("https://api.example.com/orgs/gusto/users/{user_id}")
    end
  end

  describe "workspaces — high-cardinality singletons with popular outliers" do
    # Find (host, value) pairs to test against: at the (host, "/workspaces")
    # position we want one value that hit POPULAR_MIN_COUNT and one that's a
    # singleton.
    let(:popular_pair) do
      pair = each_workspace_stat.lazy.map do |host, stats|
        name = IriGenerator::POPULAR_WORKSPACES
          .find { |n| (stats.value_counts[n] || 0) >= Iriq::Corpus::POPULAR_MIN_COUNT }
        name ? [host, name] : nil
      end.find(&:itself)
      pair || raise("seed produced no popular workspace at any host with >= #{Iriq::Corpus::POPULAR_MIN_COUNT} obs")
    end

    let(:singleton_pair) do
      pair = each_workspace_stat.lazy.map do |host, stats|
        name = stats.value_counts.find { |_, c| c == 1 }&.first
        name ? [host, name] : nil
      end.find(&:itself)
      pair || raise("seed produced no singleton workspace at any host")
    end

    def each_workspace_stat
      IriGenerator::HOSTS.filter_map do |h|
        s = corpus.stats_for(h, "/workspaces")
        s ? [h, s] : nil
      end
    end

    it "the workspace position has many distinct values across hosts" do
      total_cardinality = each_workspace_stat.sum { |_, s| s.cardinality }
      expect(total_cardinality).to be >= 30
    end

    it "explains a popular workspace as :stable_literal" do
      host, name = popular_pair
      rows = corpus.explain("https://#{host}/workspaces/#{name}")
      expect(rows.last[:classification]).to eq(:stable_literal)
    end

    it "explains a singleton workspace as :corpus_inferred_variable" do
      host, name = singleton_pair
      rows = corpus.explain("https://#{host}/workspaces/#{name}")
      expect(rows.last[:classification]).to eq(:corpus_inferred_variable)
    end

    it "corpus.normalize keeps the popular workspace literal" do
      host, name = popular_pair
      out = corpus.normalize("https://#{host}/workspaces/#{name}")
      expect(out).to eq("https://#{host}/workspaces/#{name}")
    end

    it "corpus.normalize promotes the singleton workspace to a placeholder" do
      host, name = singleton_pair
      out = corpus.normalize("https://#{host}/workspaces/#{name}")
      expect(out).to eq("https://#{host}/workspaces/{workspace}")
    end
  end

  describe "explainability of /users/me-style outliers" do
    it "marks an unseen literal at a variable-dominated position as :ambiguous" do
      rows = corpus.explain("https://app.example.com/users/somebody")
      expect(rows.last[:classification]).to eq(:ambiguous)
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
