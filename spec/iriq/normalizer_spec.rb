describe Iriq::Normalizer do
  describe ".normalize" do
    it "shapes path with hints and lowercases host" do
      expect(described_class.normalize("https://FOO.com/users/123")).to eq("https://foo.com/users/{user_id}")
    end

    it "drops default port" do
      expect(described_class.normalize("https://foo.com:443/x")).to eq("https://foo.com/x")
    end

    it "assumes https for scheme-less inputs" do
      expect(described_class.normalize("foo.com/users/456")).to eq("https://foo.com/users/{user_id}")
    end

    it "shapes query values" do
      out = described_class.normalize("https://foo.com/search?q=hello&page=2")
      expect(out).to eq("https://foo.com/search?page={integer_id}&q=hello")
    end

    it "shapes URN values with a hint derived from the namespace" do
      expect(described_class.normalize("urn:isbn:0451450523")).to eq("urn:isbn:{isbn_id}")
    end

    it "preserves Unicode" do
      expect(described_class.normalize("https://例え.テスト/こんにちは")).to eq("https://例え.テスト/こんにちは")
    end

    it "accepts an Identifier instance" do
      iri = Iriq.parse("https://foo.com/users/1")
      expect(described_class.normalize(iri)).to eq("https://foo.com/users/{user_id}")
    end

    it "supports hints: false for mechanical placeholders" do
      expect(described_class.normalize("https://foo.com/users/1", hints: false))
        .to eq("https://foo.com/users/{integer_id}")
    end
  end
end
