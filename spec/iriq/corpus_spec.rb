describe Iriq::Corpus do
  subject(:corpus) { described_class.new }

  describe "#observe" do
    it "returns an Observation with fingerprint, cluster, explanation" do
      obs = corpus.observe("https://foo.com/users/123")

      expect(obs).to be_a(Iriq::Observation)
      expect(obs.fingerprint).to eq("https://foo.com/users/{user_id}")
      expect(obs.cluster).to be_a(Iriq::Cluster)
      expect(obs.explanation).to be_an(Array)
      expect(obs.explanation.last).to include(value: "123", type: :integer_id)
    end

    it "accepts a pre-parsed Identifier" do
      iri = Iriq.parse("https://foo.com/users/1")
      expect { corpus.observe(iri) }.not_to raise_error
    end
  end

  describe "rolling aggregates" do
    before do
      corpus.observe("https://foo.com/users/1")
      corpus.observe("https://foo.com/users/2")
      corpus.observe("https://foo.com/posts/abc-123")
      corpus.observe("https://bar.com/x")
    end

    it "counts by host" do
      expect(corpus.host_counts).to eq("foo.com" => 3, "bar.com" => 1)
    end

    it "counts by path length" do
      expect(corpus.path_length_counts).to eq(2 => 3, 1 => 1)
    end

    it "counts by raw (hint-free) shape" do
      expect(corpus.raw_shape_counts).to include(
        "/users/{integer_id}" => 2,
        "/posts/{slug}"       => 1,
        "/x"                  => 1,
      )
    end

    it "counts by fingerprint (hinted shape)" do
      expect(corpus.fingerprint_counts).to include(
        "/users/{user_id}" => 2,
        "/posts/{post_id}" => 1,
      )
    end
  end

  describe "per-position stats" do
    before do
      corpus.observe("https://foo.com/users/123")
      corpus.observe("https://foo.com/users/456")
      corpus.observe("https://foo.com/users/me")
    end

    it "accumulates value frequencies under the right prefix" do
      stats = corpus.stats_for("foo.com", "/users")
      expect(stats.total).to eq(3)
      expect(stats.value_counts).to eq("123" => 1, "456" => 1, "me" => 1)
      expect(stats.type_counts).to eq(integer_id: 2, literal: 1)
    end

    it "tracks the position-0 stats too" do
      stats = corpus.stats_for("foo.com", "")
      expect(stats.value_counts).to eq("users" => 3)
    end
  end

  describe "/users/{123,456,me} learning example" do
    before do
      corpus.observe("https://foo.com/users/123")
      corpus.observe("https://foo.com/users/456")
      corpus.observe("https://foo.com/users/me")
    end

    it "clusters the integer ids together and keeps /users/me separate" do
      shapes = corpus.clusters.map(&:shape)
      expect(shapes).to contain_exactly("/users/{user_id}", "/users/me")
    end

    it "deterministic Iriq.normalize is unchanged" do
      expect(Iriq.normalize("https://foo.com/users/me")).to eq("https://foo.com/users/me")
      expect(Iriq.normalize("https://foo.com/users/789")).to eq("https://foo.com/users/{user_id}")
    end

    it "corpus.normalize keeps /users/me as a literal route" do
      expect(corpus.normalize("https://foo.com/users/me")).to eq("https://foo.com/users/me")
    end

    it "preserves /users/me even alongside many distinct other literals when it dominates" do
      # Flood with a dominant /users/me — it must stay a stable literal even
      # though the position has high cardinality.
      20.times { corpus.observe("https://foo.com/users/me") }
      5.times  { |i| corpus.observe("https://foo.com/users/alt#{i}") }

      result = corpus.explain("https://foo.com/users/me")
      expect(result[1][:classification]).to eq(:stable_literal)
      expect(corpus.normalize("https://foo.com/users/me")).to eq("https://foo.com/users/me")
    end
  end

  describe "corpus-inferred variable" do
    before do
      # Observe many distinct literal handles at position 1 — should look
      # like a variable position to the corpus even though each value is
      # mechanically a literal.
      %w[alice bob carol dave erin frank gina hank ivan jane].each do |name|
        corpus.observe("https://foo.com/users/#{name}/profile")
      end
    end

    it "explains the variable position as corpus_inferred_variable" do
      result = corpus.explain("https://foo.com/users/alice/profile")
      expect(result[1][:classification]).to eq(:corpus_inferred_variable)
    end

    it "corpus.normalize promotes the position to a placeholder" do
      out = corpus.normalize("https://foo.com/users/alice/profile")
      expect(out).to eq("https://foo.com/users/{user}/profile")
    end

    it "leaves stable literal positions alone" do
      result = corpus.explain("https://foo.com/users/alice/profile")
      expect(result[0][:classification]).to eq(:stable_literal)
      expect(result[2][:classification]).to eq(:stable_literal)
    end
  end

  describe "explainability categories" do
    it "marks classifier-variable segments as :variable_identifier" do
      corpus.observe("https://foo.com/users/123")
      result = corpus.explain("https://foo.com/users/123")
      expect(result[1][:classification]).to eq(:variable_identifier)
    end

    it "marks a dominant literal as :stable_literal" do
      9.times { corpus.observe("https://foo.com/users/me") }
      corpus.observe("https://foo.com/users/123")

      result = corpus.explain("https://foo.com/users/me")
      expect(result[1][:classification]).to eq(:stable_literal)
    end

    it "marks a non-dominant repeat literal as :rare_literal" do
      # 5 of "main" and 1 each of "rare", "rarer" — low cardinality, no
      # variable-type dominance, "main" obviously stable, "rare" minority.
      5.times { corpus.observe("https://foo.com/users/main") }
      corpus.observe("https://foo.com/users/rare")
      corpus.observe("https://foo.com/users/rarer")

      result = corpus.explain("https://foo.com/users/rare")
      expect(result[1][:classification]).to eq(:rare_literal)
    end

    it "marks an outlier literal in a mostly-variable position as :rare_literal" do
      # Many integers + one literal — the literal is a special route like
      # /users/me alongside /users/123, /users/456, ...
      6.times { |i| corpus.observe("https://foo.com/users/#{i}") }
      corpus.observe("https://foo.com/users/me")

      result = corpus.explain("https://foo.com/users/me")
      expect(result[1][:classification]).to eq(:rare_literal)
    end

    it "marks a never-seen literal in a mostly-variable position as :ambiguous" do
      # Mostly integers, ask about an unseen literal.
      6.times { |i| corpus.observe("https://foo.com/users/#{i}") }
      result = corpus.explain("https://foo.com/users/unseen")
      expect(result[1][:classification]).to eq(:ambiguous)
    end
  end

  describe "memory caps" do
    subject(:corpus) { described_class.new(max_values_per_position: 5) }

    it "caps value_counts cardinality at max_values_per_position" do
      20.times { |i| corpus.observe("https://foo.com/items/#{i}") }
      stats = corpus.stats_for("foo.com", "/items")
      expect(stats.cardinality).to eq(5)
      expect(stats.total).to eq(20)
    end

    it "caps examples per cluster (delegates to Cluster::MAX_EXAMPLES)" do
      30.times { |i| corpus.observe("https://foo.com/users/#{i}") }
      cluster = corpus.clusters.first
      expect(cluster.count).to eq(30)
      expect(cluster.examples.size).to eq(Iriq::Cluster::MAX_EXAMPLES)
    end
  end

  describe "URN handling" do
    it "doesn't crash and falls back to mechanical normalize" do
      obs = corpus.observe("urn:isbn:0451450523")
      expect(obs.fingerprint).to eq("urn:isbn:{isbn_id}")
      expect(corpus.normalize("urn:isbn:0451450523")).to eq("urn:isbn:{isbn_id}")
    end
  end

  describe "improvement over time" do
    it "the explain classification for a literal can shift as more data comes in" do
      # Start with a single literal observation — looks stable.
      corpus.observe("https://foo.com/users/alice")
      first = corpus.explain("https://foo.com/users/alice")
      expect(first[1][:classification]).to eq(:stable_literal)

      # Flood with distinct literals — corpus reclassifies the position.
      %w[bob carol dave erin frank gina hank ivan jane kara liam].each do |n|
        corpus.observe("https://foo.com/users/#{n}")
      end
      later = corpus.explain("https://foo.com/users/alice")
      expect(later[1][:classification]).to eq(:corpus_inferred_variable)
    end
  end
end
