require "json"

describe "calibration corpus" do
  fixture_path = File.expand_path("../fixtures/calibration/segments.json", __dir__)
  fixture      = JSON.parse(File.read(fixture_path))
  classifier   = Iriq::SegmentClassifier::DEFAULT

  describe "segments.json" do
    it "has entries" do
      expect(fixture["segments"]).not_to be_empty
    end

    # Every labeled segment is asserted individually so a regression shows
    # the offending value in the failure message.
    fixture["segments"].each do |entry|
      value, expected = entry["value"], entry["expected_type"].to_sym

      it "classifies #{value.inspect} as #{expected} (#{entry['category']})" do
        expect(classifier.classify(value)).to eq(expected)
      end
    end
  end
end
