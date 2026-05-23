describe Iriq::Explanation do
  describe ".explain" do
    it "annotates each segment with type and RESTful hint" do
      result = described_class.explain("https://foo.com/users/123/orders/456")
      expect(result).to eq([
        { value: "users",  type: :literal,    variable: false, hint: nil },
        { value: "123",    type: :integer_id, variable: true,  hint: "user_id" },
        { value: "orders", type: :literal,    variable: false, hint: nil },
        { value: "456",    type: :integer_id, variable: true,  hint: "order_id" },
      ])
    end

    it "uses _uuid suffix for uuid segments" do
      result = described_class.explain("https://foo.com/users/f47ac10b-58cc-4372-a567-0e02b2c3d479")
      expect(result.last[:hint]).to eq("user_uuid")
    end

    it "annotates URN segments" do
      result = described_class.explain("urn:isbn:0451450523")
      expect(result).to eq([
        { value: "isbn",       type: :literal,    variable: false, hint: nil },
        { value: "0451450523", type: :integer_id, variable: true,  hint: "isbn_id" },
      ])
    end

    it "returns empty for a URL with no path" do
      expect(described_class.explain("https://foo.com/")).to eq([])
    end

    it "leaves hint nil when no literal precedes the variable" do
      result = described_class.explain("https://foo.com/123")
      expect(result.first[:hint]).to be_nil
    end
  end
end
