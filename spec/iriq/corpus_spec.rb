describe Iriq::Corpus do
  subject(:corpus) { described_class.new }

  describe "#observe" do
    it "returns an Observation with fingerprint, cluster, explanation" do
      obs = corpus.observe("https://foo.com/users/123")

      expect(obs).to be_a(Iriq::Observation)
      expect(obs.fingerprint).to eq("https://foo.com/users/{user_id}")
      expect(obs.cluster).to be_a(Iriq::Cluster)
      expect(obs.explanation).to be_an(Array)
      expect(obs.explanation.last).to include(value: "123", type: :integer)
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
        "/users/{integer}" => 2,
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
      expect(stats.type_counts).to eq(integer: 2, literal: 1)
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

    it "keeps the scheme of opaque non-urn IRIs in fingerprints" do
      obs = corpus.observe("mailto:support@foo.com")
      expect(obs.fingerprint).to start_with("mailto:")
    end
  end

  describe "save / load round-trip" do
    it "preserves aggregates, position stats, and clusters" do
      corpus.observe("https://foo.com/users/1")
      corpus.observe("https://foo.com/users/2")
      corpus.observe("https://foo.com/posts/abc-123")

      Tempfile.open("iriq-corpus") do |f|
        corpus.save(f.path)
        restored = described_class.load(f.path)

        expect(restored.host_counts).to eq(corpus.host_counts)
        expect(restored.path_length_counts).to eq(corpus.path_length_counts)
        expect(restored.raw_shape_counts).to eq(corpus.raw_shape_counts)
        expect(restored.fingerprint_counts).to eq(corpus.fingerprint_counts)

        original_stats = corpus.stats_for("foo.com", "/users")
        restored_stats = restored.stats_for("foo.com", "/users")
        expect(restored_stats.total).to eq(original_stats.total)
        expect(restored_stats.value_counts).to eq(original_stats.value_counts)
        expect(restored_stats.type_counts).to eq(original_stats.type_counts)

        expect(restored.clusters.map(&:shape).sort).to eq(corpus.clusters.map(&:shape).sort)
      end
    end

    it "lets you keep observing after loading" do
      corpus.observe("https://foo.com/users/1")
      Tempfile.open("iriq-corpus") do |f|
        corpus.save(f.path)
        restored = described_class.load(f.path)
        restored.observe("https://foo.com/users/2")
        expect(restored.host_counts["foo.com"]).to eq(2)
        expect(restored.stats_for("foo.com", "/users").total).to eq(2)
      end
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

  describe "query param inference" do
    it "normalizes query params using cluster-informed types" do
      10.times do |i|
        corpus.observe("https://foo.com/search?q=widget&page=#{i + 1}&since=2024/01/#{(i % 28) + 1}")
      end
      out = corpus.normalize("https://foo.com/search?q=hammer&page=42&since=2024-02-15")
      # q is constant (always "widget") so it keeps its value; page is a
      # numeric variable; since varies across many literal values → {string}.
      expect(out).to eq("https://foo.com/search?page={integer}&q=hammer&since={string}")
    end

    it "params_for returns per-param presence + type for the cluster" do
      10.times do |i|
        corpus.observe("https://foo.com/items?fields=name&page=#{i}")
      end
      summary = corpus.params_for("https://foo.com/items")
      expect(summary.map { |p| p[:name] }.sort).to eq(%w[fields page])
      page = summary.find { |p| p[:name] == "page" }
      expect(page[:type]).to eq(:integer)
      expect(page[:presence]).to eq(1.0)
    end
  end

  describe "date canonicalization in normalize" do
    let(:fresh) { described_class.new }

    it "renders YYYYMMDD path dates as ISO" do
      expect(Iriq.normalize("https://foo.com/events/20240115/details"))
        .to eq("https://foo.com/events/2024-01-15/details")
    end

    it "renders YYYY/MM/DD param dates as ISO" do
      expect(Iriq.normalize("https://foo.com/events?since=2024/01/15"))
        .to eq("https://foo.com/events?since=2024-01-15")
    end

    it "renders MM/DD/YYYY (US) param dates as ISO" do
      expect(Iriq.normalize("https://foo.com/events?since=01/15/2024"))
        .to eq("https://foo.com/events?since=2024-01-15")
    end

    it "zero-pads single-digit MM/DD/YYYY components" do
      expect(Iriq.normalize("https://foo.com/events?since=1/5/2024"))
        .to eq("https://foo.com/events?since=2024-01-05")
    end
  end

  describe "float classification + :number umbrella" do
    it "classifies a float value as :float" do
      expect(Iriq::SegmentClassifier::DEFAULT.classify("3.14")).to eq(:float)
      expect(Iriq::SegmentClassifier::DEFAULT.classify("-2.5")).to eq(:float)
    end

    it "renders pure-float param values as {float}" do
      c = described_class.new
      20.times { |i| c.observe("https://foo.com/api?amt=#{i + 1}.50") }
      expect(c.normalize("https://foo.com/api?amt=99.99"))
        .to eq("https://foo.com/api?amt={float}")
    end

    it "promotes to :number when ints and floats are mixed without a clear winner" do
      c = described_class.new
      60.times { |i| c.observe("https://foo.com/api?amt=#{i + 1}.99") }
      40.times { |i| c.observe("https://foo.com/api?amt=#{i + 100}") }

      expect(c.params_for("https://foo.com/api").first[:type]).to eq(:number)
      expect(c.normalize("https://foo.com/api?amt=99.5"))
        .to eq("https://foo.com/api?amt={number}")
    end

    it "stays as :float when floats dominate above subtype threshold" do
      c = described_class.new
      85.times { |i| c.observe("https://foo.com/api?amt=#{i + 1}.99") }
      15.times { |i| c.observe("https://foo.com/api?amt=#{i + 100}") }
      expect(c.params_for("https://foo.com/api").first[:type]).to eq(:float)
    end
  end

  describe "enum detection" do
    it "surfaces a param as :enum when values are bounded across enough observations" do
      c = described_class.new
      30.times { c.observe("https://foo.com/posts?status=published") }
      20.times { c.observe("https://foo.com/posts?status=draft") }
      10.times { c.observe("https://foo.com/posts?status=archived") }

      row = c.params_for("https://foo.com/posts").first
      expect(row[:type]).to eq(:enum)
      expect(row[:values]).to eq(%w[published draft archived])
    end

    it "stays below :enum (a varying :string) under the observation threshold" do
      c = described_class.new
      5.times { c.observe("https://foo.com/posts?mode=draft") }
      5.times { c.observe("https://foo.com/posts?mode=published") }
      row = c.params_for("https://foo.com/posts").first
      expect(row[:type]).to eq(:string)
      expect(row[:values]).to be_nil
    end

    it "holds :enum when a stray one-off value would have broken the old gate" do
      c = described_class.new
      30.times { c.observe("https://foo.com/posts?status=published") }
      20.times { c.observe("https://foo.com/posts?status=draft") }
      c.observe("https://foo.com/posts?status=typo") # single straggler
      row = c.params_for("https://foo.com/posts").first
      expect(row[:type]).to eq(:enum)
      # the straggler is excluded from the established set
      expect(row[:values]).to eq(%w[published draft])
    end

    it "does NOT promote when cardinality is too high" do
      c = described_class.new
      40.times { |i| c.observe("https://foo.com/posts?id=#{i}") }
      row = c.params_for("https://foo.com/posts").first
      expect(row[:type]).to eq(:integer)
    end

    it "normalize renders {enum} placeholder without inlining values" do
      c = described_class.new
      30.times { c.observe("https://foo.com/posts?status=published") }
      20.times { c.observe("https://foo.com/posts?status=draft") }
      expect(c.normalize("https://foo.com/posts?status=other"))
        .to eq("https://foo.com/posts?status={enum}")
    end

    it "exposes a value_distribution for :enum positions" do
      c = described_class.new
      30.times { c.observe("https://foo.com/posts?status=published") }
      20.times { c.observe("https://foo.com/posts?status=draft") }

      row = c.params_for("https://foo.com/posts").first
      expect(row[:value_distribution]).to eq("published" => 0.6, "draft" => 0.4)
    end
  end

  describe "the const → string → enum ladder" do
    it "treats a single-valued param as a constant (renders the value)" do
      c = described_class.new
      10.times { c.observe("https://foo.com/x?format=json") }
      row = c.params_for("https://foo.com/x").first
      expect(row[:type]).to eq(:literal)
      expect(c.normalize("https://foo.com/x?format=json"))
        .to eq("https://foo.com/x?format=json")
    end

    it "keeps a single-valued param a constant even past the enum threshold" do
      c = described_class.new
      40.times { c.observe("https://foo.com/x?format=json") } # well over ENUM_MIN_OBSERVATIONS
      row = c.params_for("https://foo.com/x").first
      expect(row[:type]).to eq(:literal) # a lone value is a constant, not an enum
      expect(c.normalize("https://foo.com/x?format=json"))
        .to eq("https://foo.com/x?format=json")
    end

    it "calls a varying literal param :string and renders {string}" do
      c = described_class.new
      %w[asc desc name -name created].each { |v| c.observe("https://foo.com/x?sort=#{v}") }
      row = c.params_for("https://foo.com/x").first
      expect(row[:type]).to eq(:string)
      expect(c.normalize("https://foo.com/x?sort=updated"))
        .to eq("https://foo.com/x?sort={string}")
    end

    it "graduates string → enum as a bounded set proves itself" do
      c = described_class.new
      3.times { c.observe("https://foo.com/x?sort=asc") }
      3.times { c.observe("https://foo.com/x?sort=desc") }
      expect(c.params_for("https://foo.com/x").first[:type]).to eq(:string)

      17.times { c.observe("https://foo.com/x?sort=asc") }
      17.times { c.observe("https://foo.com/x?sort=desc") }
      expect(c.params_for("https://foo.com/x").first[:type]).to eq(:enum)
    end
  end

  describe "confidence score" do
    it "is reported on every param, bounded in (0, 1]" do
      c = described_class.new
      c.observe("https://foo.com/x?a=1")
      conf = c.params_for("https://foo.com/x").first[:confidence]
      expect(conf).to be > 0.0
      expect(conf).to be <= 1.0
    end

    it "rises monotonically with more observations and approaches 1" do
      c = described_class.new
      confs = []
      total = 0
      [1, 10, 100, 1000].each do |target|
        (target - total).times { c.observe("https://foo.com/x?a=1") }
        total = target
        confs << c.params_for("https://foo.com/x").first[:confidence]
      end

      expect(confs).to eq(confs.sort)             # non-decreasing
      expect(confs.uniq.length).to eq(confs.length) # strictly increasing
      expect(confs.last).to be > 0.9              # lots of evidence → near-certain
    end
  end

  describe "value distributions" do
    it "exposes a value_distribution for :boolean positions" do
      c = described_class.new
      90.times { c.observe("https://foo.com/x?ok=true") }
      10.times { c.observe("https://foo.com/x?ok=false") }
      row = c.params_for("https://foo.com/x").first
      expect(row[:type]).to eq(:boolean)
      expect(row[:value_distribution]).to eq("true" => 0.9, "false" => 0.1)
    end

    it "exposes a subtype_distribution for :number positions" do
      c = described_class.new
      40.times { |i| c.observe("https://foo.com/api?amt=#{i + 1}") }
      60.times { |i| c.observe("https://foo.com/api?amt=#{i + 1}.5") }
      row = c.params_for("https://foo.com/api").first
      expect(row[:type]).to eq(:number)
      expect(row[:subtype_distribution]).to eq(integer: 0.4, float: 0.6)
    end
  end

  describe "param-name hints" do
    it "lifts a generic-valued param to its hinted type" do
      c = described_class.new
      %w[unknown tbd foo bar baz qux quux corge grault garply waldo fred].each do |v|
        c.observe("https://foo.com/x?phone=#{v}")
      end
      row = c.params_for("https://foo.com/x").first
      expect(row[:type]).to eq(:phone)
    end

    it "doesn't override a specific value type" do
      c = described_class.new
      5.times { |i| c.observe("https://foo.com/x?phone=#{1000 + i}") }
      row = c.params_for("https://foo.com/x").first
      expect(row[:type]).to eq(:integer)
    end
  end

  describe ":file param summary" do
    it "surfaces a kind_distribution for file-typed params" do
      c = described_class.new
      %w[a.png b.jpg c.gif d.pdf e.csv].each do |f|
        c.observe("https://foo.com/upload?asset=#{f}")
      end
      row = c.params_for("https://foo.com/upload").first
      expect(row[:type]).to eq(:file)
      expect(row[:kind_distribution]).to include(image: be > 0.0, document: be > 0.0, data: be > 0.0)
    end
  end

  describe "http_status promotion" do
    it "surfaces a param as :http_status when integer values fall in 100..599" do
      c = described_class.new
      [200, 200, 200, 404, 500].each do |s|
        c.observe("https://foo.com/api?status=#{s}")
      end
      row = c.params_for("https://foo.com/api").first
      expect(row[:type]).to eq(:http_status)
    end

    it "stays as :integer when values exceed the status window" do
      c = described_class.new
      [200, 999, 1000].each do |s|
        c.observe("https://foo.com/api?status=#{s}")
        c.observe("https://foo.com/api?status=#{s + 1}")
      end
      row = c.params_for("https://foo.com/api").first
      expect(row[:type]).to eq(:integer)
    end
  end

  describe "host_strategy" do
    it ":registrable collapses subdomains" do
      c = described_class.new(host_strategy: :registrable)
      c.observe("https://api.foo.com/users/1")
      c.observe("https://app.foo.com/users/2")
      expect(c.host_counts).to eq("foo.com" => 2)
      expect(c.clusters.size).to eq(1)
      expect(c.clusters.first.host).to eq("foo.com")
    end

    it ":registrable handles multi-label public suffixes (co.uk)" do
      c = described_class.new(host_strategy: :registrable)
      c.observe("https://blog.example.co.uk/posts/1")
      c.observe("https://news.example.co.uk/posts/2")
      expect(c.host_counts).to eq("example.co.uk" => 2)
    end

    it ":none pools all hosts into shape-only clusters" do
      c = described_class.new(host_strategy: :none)
      c.observe("https://foo.com/users/1")
      c.observe("https://bar.io/users/2")
      c.observe("https://baz.net/users/3")
      expect(c.clusters.size).to eq(1)
      expect(c.host_counts).to eq("" => 3)
    end

    it ":full (default) keeps original host" do
      c = described_class.new
      c.observe("https://api.foo.com/users/1")
      c.observe("https://app.foo.com/users/2")
      expect(c.clusters.size).to eq(2)
    end

    it "rejects unknown host_strategy" do
      expect { described_class.new(host_strategy: :bogus) }.to raise_error(ArgumentError)
    end
  end

  describe ":date quorum threshold" do
    it "does NOT promote a param to :date when date-typed observations are below 80%" do
      corpus = described_class.new
      70.times { |i| corpus.observe("https://foo.com/p?d=2024-01-#{((i % 28) + 1).to_s.rjust(2, "0")}") }
      30.times { corpus.observe("https://foo.com/p?d=tbd") }

      summary = corpus.params_for("https://foo.com/p").first
      expect(summary[:type]).to eq(:literal)
      # A clear date value is NOT canonicalized — the corpus isn't confident
      # enough to treat this param as a date.
      expect(corpus.normalize("https://foo.com/p?d=2024/06/15"))
        .to eq("https://foo.com/p?d=2024/06/15")
    end

    it "promotes to :date at or above 80% confidence" do
      corpus = described_class.new
      90.times { |i| corpus.observe("https://foo.com/p?d=2024-01-#{((i % 28) + 1).to_s.rjust(2, "0")}") }
      10.times { corpus.observe("https://foo.com/p?d=tbd") }

      expect(corpus.params_for("https://foo.com/p").first[:type]).to eq(:date)
      expect(corpus.normalize("https://foo.com/p?d=2024/06/15"))
        .to eq("https://foo.com/p?d=2024-06-15")
    end
  end
end
