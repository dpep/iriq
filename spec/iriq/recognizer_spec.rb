describe Iriq::Recognizer do
  describe ".ensemble" do
    let(:high) do
      Class.new(Iriq::Recognizer) do
        def try(segment)
          return nil unless segment == "match"
          { type: :high_type, confidence: 1.0, specificity: Iriq::Specificity::SEMANTIC }
        end
      end.new
    end

    let(:low) do
      Class.new(Iriq::Recognizer) do
        def try(segment)
          return nil unless segment == "match"
          { type: :low_type, confidence: 1.0, specificity: Iriq::Specificity::TYPED }
        end
      end.new
    end

    let(:never_fires) do
      Class.new(Iriq::Recognizer) do
        def try(_segment) = nil
      end.new
    end

    it "returns nil when no recognizer fires" do
      expect(Iriq::Recognizer.ensemble("nope", [high, low])).to be_nil
    end

    it "returns the only firing verdict" do
      v = Iriq::Recognizer.ensemble("match", [high, never_fires])
      expect(v[:type]).to eq(:high_type)
    end

    it "picks the highest specificity × confidence" do
      v = Iriq::Recognizer.ensemble("match", [low, high])
      expect(v[:type]).to eq(:high_type)
    end

    it "is stable when both recognizers tie — earlier wins" do
      tie_a = Class.new(Iriq::Recognizer) do
        def try(_) = { type: :a, confidence: 1.0, specificity: 0.5 }
      end.new
      tie_b = Class.new(Iriq::Recognizer) do
        def try(_) = { type: :b, confidence: 1.0, specificity: 0.5 }
      end.new

      expect(Iriq::Recognizer.ensemble("x", [tie_a, tie_b])[:type]).to eq(:a)
      expect(Iriq::Recognizer.ensemble("x", [tie_b, tie_a])[:type]).to eq(:b)
    end
  end
end
