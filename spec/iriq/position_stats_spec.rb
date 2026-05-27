describe Iriq::PositionStats do
  subject(:stats) { described_class.new(max_values: 3) }

  describe "#observe" do
    it "tracks total and per-value counts" do
      stats.observe("a", :literal)
      stats.observe("a", :literal)
      stats.observe("b", :literal)

      expect(stats.total).to eq(3)
      expect(stats.value_counts).to eq("a" => 2, "b" => 1)
    end

    it "tracks per-type counts" do
      stats.observe("a", :literal)
      stats.observe("1", :integer)
      stats.observe("2", :integer)

      expect(stats.type_counts).to eq(literal: 1, integer: 2)
    end

    it "caps cardinality at max_values but keeps total accurate" do
      4.times { |i| stats.observe("v#{i}", :literal) }
      stats.observe("v0", :literal) # existing key still bumps

      expect(stats.total).to eq(5)
      expect(stats.cardinality).to eq(3)
      expect(stats.value_counts["v0"]).to eq(2)
      expect(stats.value_counts).not_to have_key("v3")
    end
  end

  describe "#variable_fraction" do
    let(:classifier) { Iriq::SegmentClassifier.new }

    it "returns the share of observations whose type was variable" do
      stats.observe("foo", :literal)
      stats.observe("1",   :integer)
      stats.observe("2",   :integer)
      stats.observe("3",   :integer)

      expect(stats.variable_fraction(classifier)).to be_within(0.001).of(0.75)
    end

    it "is 0 when no observations" do
      expect(stats.variable_fraction(classifier)).to eq(0.0)
    end
  end

  describe "#value_fraction" do
    it "returns count/total for a known value" do
      stats.observe("a", :literal)
      stats.observe("a", :literal)
      stats.observe("b", :literal)

      expect(stats.value_fraction("a")).to be_within(0.001).of(2.0 / 3.0)
      expect(stats.value_fraction("missing")).to eq(0.0)
    end
  end
end
