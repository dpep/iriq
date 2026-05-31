describe Iriq::Shape do
  describe ".from_segments" do
    it "derives entries from raw segments" do
      shape = described_class.from_segments(%w[users 123])
      types = shape.entries.map { |e| e[:type] }
      expect(types).to eq(%i[literal integer])
    end

    it "yields '/' for empty / nil segments" do
      expect(described_class.from_segments([]).to_s).to eq("/")
      expect(described_class.from_segments(nil).to_s).to eq("/")
    end
  end

  describe "#render" do
    let(:shape) { described_class.from_segments(%w[users 123 orders 456]) }

    it "renders with hints by default" do
      expect(shape.render).to eq("/users/{user_id}/orders/{order_id}")
    end

    it "renders without hints when asked" do
      expect(shape.render(hints: false)).to eq("/users/{integer}/orders/{integer}")
    end

    it "canonicalizes dates when asked" do
      dated = described_class.from_segments(["events", "2024/01/15"])
      expect(dated.render(canonical_dates: true)).to eq("/events/2024-01-15")
      expect(dated.render(canonical_dates: false)).to eq("/events/{date}")
    end

    it "canonicalizes currencies when asked" do
      curr = described_class.from_segments(["pricing", "usd"])
      expect(curr.render(canonical_currencies: true)).to eq("/pricing/USD")
    end
  end

  describe "structural equality" do
    it "compares equal when segments classify the same" do
      a = described_class.from_segments(%w[users 1])
      b = described_class.from_segments(%w[users 999])
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "is not equal when literals differ" do
      a = described_class.from_segments(%w[users 1])
      b = described_class.from_segments(%w[posts 1])
      expect(a).not_to eq(b)
    end
  end

  describe "round-trip dump / from_dump" do
    it "preserves entries and rendering" do
      shape = described_class.from_segments(%w[users 123])
      round = described_class.from_dump(shape.to_dump)
      expect(round).to eq(shape)
      expect(round.render).to eq(shape.render)
    end
  end
end
