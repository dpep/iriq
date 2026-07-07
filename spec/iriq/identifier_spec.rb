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

    it "preserves the scheme of opaque non-urn IRIs" do
      expect(Iriq.parse("mailto:support@foo.com").canonical).to eq("mailto:support@foo.com")
      expect(Iriq.parse("tel:+1-415-555-0132").canonical).to eq("tel:+1-415-555-0132")
      expect(Iriq.parse("data:text/plain,hi").canonical).to eq("data:text/plain,hi")
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
