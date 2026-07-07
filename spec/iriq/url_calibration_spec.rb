require "json"

describe "URL calibration corpus" do
  fixture_path = File.expand_path("../fixtures/calibration/urls.json", __dir__)
  fixture      = JSON.parse(File.read(fixture_path))

  describe "urls.json" do
    it "has entries" do
      expect(fixture["urls"]).not_to be_empty
    end

    fixture["urls"].each do |entry|
      input = entry["input"]

      if entry["expected_error"]
        it "rejects #{input.inspect} (#{entry['category']})" do
          expect { Iriq.normalize(input) }.to raise_error(Iriq::ParseError)
        end
      else
        it "normalizes #{input.inspect} (#{entry['category']})" do
          expect(Iriq.normalize(input)).to eq(entry["expected_normalize"])
        end
      end
    end
  end
end
