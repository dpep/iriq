describe Iriq do
  describe ".parse" do
    it "returns an Identifier" do
      expect(Iriq.parse("https://foo.com/")).to be_a(Iriq::Identifier)
    end
  end

  describe ".normalize" do
    it "shapes the path" do
      expect(Iriq.normalize("https://foo.com/users/123")).to eq("https://foo.com/users/{integer_id}")
    end
  end

  describe ".explain" do
    it "returns segment annotations" do
      result = Iriq.explain("https://foo.com/users/123")
      expect(result).to eq([
        { value: "users", type: :literal,    variable: false },
        { value: "123",   type: :integer_id, variable: true },
      ])
    end
  end
end
