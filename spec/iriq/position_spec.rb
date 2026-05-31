describe Iriq::Position do
  describe ".path / .query" do
    it "constructs path positions" do
      p = described_class.path(host: "foo.com", prefix: "/users")
      expect(p.host).to    eq("foo.com")
      expect(p.scope).to   eq(:path)
      expect(p.locator).to eq("/users")
      expect(p).to be_path
    end

    it "constructs query positions" do
      p = described_class.query(host: "foo.com", name: "page")
      expect(p.host).to    eq("foo.com")
      expect(p.scope).to   eq(:query)
      expect(p.locator).to eq("page")
      expect(p).to be_query
    end
  end

  describe "validation" do
    it "rejects unknown scopes" do
      expect {
        described_class.new(host: "x", scope: :bogus, locator: "y")
      }.to raise_error(ArgumentError)
    end
  end

  describe "value semantics" do
    let(:a) { described_class.path(host: "foo.com", prefix: "/u") }
    let(:b) { described_class.path(host: "foo.com", prefix: "/u") }
    let(:c) { described_class.path(host: "bar.com", prefix: "/u") }

    it "compares by (host, scope, locator)" do
      expect(a).to eq(b)
      expect(a).not_to eq(c)
    end

    it "hashes by (host, scope, locator)" do
      h = { a => 1 }
      expect(h[b]).to eq(1)
    end

    it "distinguishes path and query positions even with same locator" do
      pp = described_class.path(host: "x", prefix: "name")
      qp = described_class.query(host: "x", name: "name")
      expect(pp).not_to eq(qp)
    end
  end

  describe "round-trip dump / from_dump" do
    it "preserves equality" do
      p   = described_class.query(host: "foo.com", name: "page")
      out = described_class.from_dump(p.to_dump)
      expect(out).to eq(p)
    end
  end
end
