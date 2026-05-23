describe Iriq::Parser do
  describe ".parse" do
    it "parses a standard URL" do
      iri = described_class.parse("https://foo.com/users/123")
      expect(iri.scheme).to eq("https")
      expect(iri.host).to eq("foo.com")
      expect(iri.port).to be_nil
      expect(iri.path_segments).to eq(["users", "123"])
      expect(iri.query_params).to eq({})
      expect(iri.fragment).to be_nil
      expect(iri.url?).to be true
    end

    it "lowercases scheme and host" do
      iri = described_class.parse("HTTPS://FOO.COM/Bar")
      expect(iri.scheme).to eq("https")
      expect(iri.host).to eq("foo.com")
      expect(iri.path_segments).to eq(["Bar"])
    end

    it "drops default ports" do
      expect(described_class.parse("https://foo.com:443/").port).to be_nil
      expect(described_class.parse("http://foo.com:80/").port).to be_nil
    end

    it "keeps non-default ports" do
      expect(described_class.parse("https://foo.com:8443/").port).to eq(8443)
    end

    it "preserves original input" do
      iri = described_class.parse("  https://Foo.com/  ")
      expect(iri.original).to eq("  https://Foo.com/  ")
    end

    it "normalizes dot segments" do
      iri = described_class.parse("https://foo.com/a/./b/../c")
      expect(iri.path_segments).to eq(["a", "c"])
    end

    it "drops empty path segments from duplicate slashes" do
      iri = described_class.parse("https://foo.com//a///b")
      expect(iri.path_segments).to eq(["a", "b"])
    end

    it "parses query string into params" do
      iri = described_class.parse("https://foo.com/q?a=1&b=hello&c=")
      expect(iri.query_params).to eq("a" => "1", "b" => "hello", "c" => "")
    end

    it "parses fragment" do
      iri = described_class.parse("https://foo.com/x#top")
      expect(iri.fragment).to eq("top")
    end

    it "assumes https for scheme-less host-like inputs" do
      iri = described_class.parse("foo.com/users/456")
      expect(iri.scheme).to eq("https")
      expect(iri.host).to eq("foo.com")
      expect(iri.path_segments).to eq(["users", "456"])
    end

    it "parses URN-style identifiers" do
      iri = described_class.parse("urn:isbn:0451450523")
      expect(iri.urn?).to be true
      expect(iri.scheme).to eq("urn")
      expect(iri.nss).to eq("isbn:0451450523")
      expect(iri.host).to be_nil
      expect(iri.path_segments).to eq([])
    end

    it "parses Unicode IRIs without losing the display form" do
      iri = described_class.parse("https://例え.テスト/こんにちは")
      expect(iri.host).to eq("例え.テスト")
      expect(iri.path_segments).to eq(["こんにちは"])
    end

    it "raises ParseError on nil input" do
      expect { described_class.parse(nil) }.to raise_error(Iriq::ParseError, /nil/)
    end

    it "raises ParseError on empty input" do
      expect { described_class.parse("   ") }.to raise_error(Iriq::ParseError, /empty/)
    end

    it "raises ParseError on non-string input" do
      expect { described_class.parse(123) }.to raise_error(Iriq::ParseError, /String/)
    end

    it "raises ParseError on inputs that look like neither a URL nor a host" do
      expect { described_class.parse("just-some-token") }.to raise_error(Iriq::ParseError)
    end
  end
end
