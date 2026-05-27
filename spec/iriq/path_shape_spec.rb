describe Iriq::PathShape do
  describe ".for" do
    it "returns / for an empty path" do
      expect(described_class.for([])).to eq("/")
    end

    it "shapes a simple path with a hint" do
      expect(described_class.for(["users", "123"])).to eq("/users/{user_id}")
    end

    it "shapes nested ids with hints" do
      expect(described_class.for(["users", "123", "orders", "456"]))
        .to eq("/users/{user_id}/orders/{order_id}")
    end

    it "uses _uuid suffix when the segment is a uuid" do
      expect(described_class.for(["users", "f47ac10b-58cc-4372-a567-0e02b2c3d479"]))
        .to eq("/users/{user_uuid}")
    end

    it "leaves true literals alone" do
      expect(described_class.for(["api", "alpha", "status"])).to eq("/api/alpha/status")
    end

    it "classifies version segments separately from path literals" do
      # v1 / v2.0.1 classify as :version. Semantic types (version, locale,
      # currency, boolean, date) skip the noun-singularize hint so the type
      # itself surfaces instead of a misleading {api_id} placeholder.
      expect(described_class.for(["api", "v1", "status"])).to eq("/api/{version}/status")
    end

    it "shapes dates and slugs (with hints when possible)" do
      # Date is a semantic type — surface as {date}, not {post_id}.
      expect(described_class.for(["posts", "2024-05-23", "my-cool-post"]))
        .to eq("/posts/{date}/{slug}")
    end

    it "skips the hint when no literal precedes the variable" do
      expect(described_class.for(["123"])).to eq("/{integer}")
    end

    it "falls back to raw types with hints: false" do
      expect(described_class.for(["users", "123"], hints: false)).to eq("/users/{integer}")
    end
  end
end
