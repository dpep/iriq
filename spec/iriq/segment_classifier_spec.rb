describe Iriq::SegmentClassifier do
  subject(:classifier) { described_class.new }

  describe "#classify" do
    {
      "users"                                => :literal,
      "Profile"                              => :literal,
      "123"                                  => :integer_id,
      "0"                                    => :integer_id,
      "9999999"                              => :integer_id,
      "f47ac10b-58cc-4372-a567-0e02b2c3d479" => :uuid,
      "2024-05-23"                           => :date,
      "2024-05-23T10:30:00Z"                 => :timestamp,
      "2024-05-23 10:30:00"                  => :timestamp,
      "1716470400"                           => :timestamp,
      "1716470400000"                        => :timestamp,
      "d41d8cd98f00b204e9800998ecf8427e"     => :hash,
      "my-cool-post"                         => :slug,
      "my_cool_post"                         => :slug,
      "abc123XYZ"                            => :opaque_id,
      "こんにちは"                              => :literal,
      "192.168.1.1"                          => :ipv4,
      "10.0.0.1"                             => :ipv4,
      "0.0.0.0"                              => :ipv4,
      "999.999.999.999"                      => :opaque_id,
      "1.2.3"                                => :opaque_id,
      "::1"                                  => :ipv6,
      "::"                                   => :ipv6,
      "2001:db8::1"                          => :ipv6,
      "2001:0db8:0000:0000:0000:ff00:0042:8329" => :ipv6,
      "fe80::1"                              => :ipv6,
      "12:34"                                => :literal,
      "deadbeef"                             => :literal,
      "https://foo.com/bar"                  => :url,
      "http://x"                             => :url,
      "ftp://files.example.com/x"            => :url,
      "alice@example.com"                    => :email,
      "user.name+tag@sub.example.co.uk"      => :email,
      "no-at-sign"                           => :slug,
    }.each do |input, expected|
      it "classifies #{input.inspect} as #{expected}" do
        expect(classifier.classify(input)).to eq(expected)
      end
    end

    it "treats nil and empty as literal" do
      expect(classifier.classify(nil)).to eq(:literal)
      expect(classifier.classify("")).to eq(:literal)
    end
  end

  describe "#variable?" do
    it "is false for :literal only" do
      expect(classifier.variable?(:literal)).to be false
      expect(classifier.variable?(:integer_id)).to be true
      expect(classifier.variable?(:uuid)).to be true
    end
  end
end
