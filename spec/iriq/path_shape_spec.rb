describe Iriq::PathShape do
  describe ".for" do
    it "returns / for an empty path" do
      expect(described_class.for([])).to eq("/")
    end

    it "shapes a simple path" do
      expect(described_class.for(["users", "123"])).to eq("/users/{integer_id}")
    end

    it "shapes nested ids" do
      expect(described_class.for(["users", "123", "orders", "456"])).to eq("/users/{integer_id}/orders/{integer_id}")
    end

    it "leaves literals alone" do
      expect(described_class.for(["api", "v1", "status"])).to eq("/api/v1/status")
    end

    it "shapes UUIDs" do
      expect(described_class.for(["org", "f47ac10b-58cc-4372-a567-0e02b2c3d479"])).to eq("/org/{uuid}")
    end

    it "shapes dates and slugs" do
      expect(described_class.for(["posts", "2024-05-23", "my-cool-post"])).to eq("/posts/{date}/{slug}")
    end
  end
end
