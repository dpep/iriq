describe Iriq::Identifier do
  describe "#canonical" do
    it "reconstructs a URL" do
      iri = Iriq.parse("https://foo.com/users/123?x=1#top")
      expect(iri.canonical).to eq("https://foo.com/users/123?x=1#top")
    end

    it "omits default port" do
      iri = Iriq.parse("https://foo.com:443/")
      expect(iri.canonical).to eq("https://foo.com")
    end

    it "keeps a non-default port" do
      iri = Iriq.parse("https://foo.com:8443/x")
      expect(iri.canonical).to eq("https://foo.com:8443/x")
    end

    it "reconstructs a URN" do
      iri = Iriq.parse("urn:isbn:0451450523")
      expect(iri.canonical).to eq("urn:isbn:0451450523")
    end

    it "preserves Unicode" do
      iri = Iriq.parse("https://例え.テスト/こんにちは")
      expect(iri.canonical).to eq("https://例え.テスト/こんにちは")
    end
  end

  describe "equality" do
    it "compares by canonical form" do
      a = Iriq.parse("https://Foo.com/x")
      b = Iriq.parse("https://foo.com/x")
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end
  end
end
