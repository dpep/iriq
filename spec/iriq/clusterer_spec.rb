describe Iriq::Clusterer do
  subject(:clusterer) { described_class.new }

  describe "#add and #clusters" do
    it "groups identifiers by host + shape" do
      clusterer.add("https://foo.com/users/123")
      clusterer.add("https://foo.com/users/456")
      clusterer.add("https://foo.com/users/789/orders/1")

      expect(clusterer.size).to eq(2)

      shapes = clusterer.clusters.map(&:shape)
      expect(shapes).to contain_exactly(
        "/users/{user_id}",
        "/users/{user_id}/orders/{order_id}",
      )
    end

    it "tracks count and examples per cluster" do
      3.times { |i| clusterer.add("https://foo.com/users/#{i}") }

      cluster = clusterer.clusters.first
      expect(cluster.count).to eq(3)
      expect(cluster.examples.size).to eq(3)
    end

    it "caps examples at MAX_EXAMPLES" do
      30.times { |i| clusterer.add("https://foo.com/users/#{i}") }
      cluster = clusterer.clusters.first
      expect(cluster.count).to eq(30)
      expect(cluster.examples.size).to eq(Iriq::Cluster::MAX_EXAMPLES)
    end

    it "distinguishes hosts" do
      clusterer.add("https://foo.com/x/1")
      clusterer.add("https://bar.com/x/1")
      expect(clusterer.size).to eq(2)
    end

    it "produces per-position segment stats" do
      clusterer.add("https://foo.com/users/1")
      clusterer.add("https://foo.com/users/2")

      cluster = clusterer.clusters.first
      stats = cluster.segment_stats
      expect(stats[0]).to eq(position: 0, stable: true,  values: { "users" => 2 })
      expect(stats[1]).to eq(position: 1, stable: false, values: { "1" => 1, "2" => 1 })
    end

    it "clusters URNs by scheme + namespace + shape" do
      clusterer.add("urn:isbn:0451450523")
      clusterer.add("urn:isbn:0140449116")
      clusterer.add("urn:uuid:f47ac10b-58cc-4372-a567-0e02b2c3d479")

      expect(clusterer.size).to eq(2)
    end
  end

  describe "#explain" do
    it "marks a position stable when all observed values match" do
      clusterer.add("https://foo.com/users/1")
      clusterer.add("https://foo.com/users/2")
      clusterer.add("https://foo.com/users/3")

      result = clusterer.explain("https://foo.com/users/999")
      expect(result[0]).to eq(value: "users", type: :literal,    variable: false, hint: nil,       stable: true)
      expect(result[1]).to eq(value: "999",   type: :integer_id, variable: true,  hint: "user_id", stable: false)
    end

    it "returns variable=false when the position turns out to be stable in cluster" do
      # all observed shape="/x/{integer_id}" but the integer is always "5"
      clusterer.add("https://foo.com/x/5")
      clusterer.add("https://foo.com/x/5")

      result = clusterer.explain("https://foo.com/x/5")
      expect(result[1][:stable]).to be true
      expect(result[1][:variable]).to be false
    end

    it "works for unseen inputs (no cluster yet)" do
      result = clusterer.explain("https://foo.com/users/1")
      expect(result).to eq([
        { value: "users", type: :literal,    variable: false, hint: nil,       stable: false },
        { value: "1",     type: :integer_id, variable: true,  hint: "user_id", stable: false },
      ])
    end
  end
end
