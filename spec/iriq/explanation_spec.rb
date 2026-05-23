describe Iriq::Explanation do
  describe ".explain" do
    it "annotates each segment" do
      result = described_class.explain("https://foo.com/users/123/orders/456")
      expect(result).to eq([
        { value: "users",  type: :literal,    variable: false },
        { value: "123",    type: :integer_id, variable: true },
        { value: "orders", type: :literal,    variable: false },
        { value: "456",    type: :integer_id, variable: true },
      ])
    end

    it "annotates URN segments" do
      result = described_class.explain("urn:isbn:0451450523")
      expect(result).to eq([
        { value: "isbn",       type: :literal,    variable: false },
        { value: "0451450523", type: :integer_id, variable: true },
      ])
    end

    it "returns empty for a URL with no path" do
      expect(described_class.explain("https://foo.com/")).to eq([])
    end
  end
end
