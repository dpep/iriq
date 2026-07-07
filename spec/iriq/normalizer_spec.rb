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
      expect(out).to eq("https://foo.com/search?page={integer}&q=hello")
    end

    it "shapes URN values with a hint derived from the namespace" do
      expect(described_class.normalize("urn:isbn:0451450523")).to eq("urn:isbn:{isbn_id}")
    end

    it "preserves the scheme of opaque non-urn IRIs" do
      expect(described_class.normalize("mailto:support@foo.com")).to eq("mailto:support@foo.com")
      expect(described_class.normalize("tel:+1-415-555-0132")).to eq("tel:+1-415-555-0132")
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
        .to eq("https://foo.com/users/{integer}")
    end

    it "canonicalizes currency segments to upper case" do
      expect(described_class.normalize("https://shop.com/pricing/usd/checkout"))
        .to eq("https://shop.com/pricing/USD/checkout")
    end

    it "canonicalizes currency query params to upper case" do
      out = described_class.normalize("https://shop.com/price?currency=eur")
      expect(out).to eq("https://shop.com/price?currency=EUR")
    end

    it "collapses ipv4/ipv6 to {ip} in placeholder form" do
      expect(described_class.normalize("https://foo.com/probe/192.168.1.1"))
        .to eq("https://foo.com/probe/{ip}")
      expect(described_class.normalize("https://foo.com/probe/::1"))
        .to eq("https://foo.com/probe/{ip}")
    end

    it "surfaces semantic types as {type} rather than noun-singular hints" do
      # version: don't render as {api_id}.
      expect(described_class.normalize("https://foo.com/api/v1/status"))
        .to eq("https://foo.com/api/{version}/status")
    end

    it "classifies file-shaped path segments as {file}" do
      expect(described_class.normalize("https://foo.com/uploads/image.png"))
        .to eq("https://foo.com/uploads/{file}")
    end

    it "classifies NANP phone path segments as {phone}" do
      expect(described_class.normalize("https://foo.com/contact/555-666-7777"))
        .to eq("https://foo.com/contact/{phone}")
    end

    it "uses param-name hints when the value is too generic" do
      # `?phone=unknown` — value classifies as :literal but param name lifts it.
      out = described_class.normalize("https://foo.com/x?phone=unknown&email=tbd")
      expect(out).to eq("https://foo.com/x?email={email}&phone={phone}")
    end

    it "doesn't let param-name hints override a specific value type" do
      # `?phone=123` — value classifies as :integer; param-name hint only fires
      # for generic types, so the integer wins.
      out = described_class.normalize("https://foo.com/x?phone=12345")
      expect(out).to eq("https://foo.com/x?phone={integer}")
    end
  end
end
