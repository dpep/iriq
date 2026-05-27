describe Iriq::Trace do
  describe ".for" do
    it "returns a trace structure with input + normalized + path" do
      tr = described_class.for("https://foo.com/users/123")
      expect(tr[:input]).to eq("https://foo.com/users/123")
      expect(tr[:normalized]).to eq("https://foo.com/users/{user_id}")
      expect(tr[:host]).to eq("foo.com")
      expect(tr[:path]).to be_an(Array)
    end

    it "notes hint suppression for semantic types" do
      tr = described_class.for("https://foo.com/api/v1/status")
      v1_row = tr[:path].find { |r| r[:value] == "v1" }
      expect(v1_row[:type]).to eq(:version)
      expect(v1_row[:output]).to eq("{version}")
      expect(v1_row[:notes]).to include(/semantic type.*{version}.*not {api_id}/)
    end

    it "notes currency upcasing" do
      tr = described_class.for("https://shop.com/pricing/usd")
      usd_row = tr[:path].find { |r| r[:value] == "usd" }
      expect(usd_row[:output]).to eq("USD")
      expect(usd_row[:notes]).to include(/currency upcase/)
    end

    it "notes ip umbrella collapse" do
      tr = described_class.for("https://foo.com/probe/192.168.1.1")
      ip_row = tr[:path].find { |r| r[:value] == "192.168.1.1" }
      expect(ip_row[:output]).to eq("{ip}")
      expect(ip_row[:notes]).to include(/ip umbrella collapse/)
    end

    it "notes param-name hint lifts" do
      tr = described_class.for("https://foo.com/x?phone=unknown")
      phone_row = tr[:query].find { |r| r[:name] == "phone" }
      expect(phone_row[:type]).to eq(:phone)
      expect(phone_row[:output]).to eq("{phone}")
      expect(phone_row[:notes]).to include(/param-name hint/)
    end

    it "handles URN inputs" do
      tr = described_class.for("urn:isbn:0451450523")
      expect(tr[:normalized]).to eq("urn:isbn:{isbn_id}")
      expect(tr[:path].last[:output]).to eq("{isbn_id}")
    end
  end
end
