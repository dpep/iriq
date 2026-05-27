describe Iriq::SegmentClassifier do
  subject(:classifier) { described_class.new }

  describe "#classify" do
    {
      "users"                                => :literal,
      "Profile"                              => :literal,
      "123"                                  => :integer,
      "0"                                    => :integer,
      "9999999"                              => :integer,
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
      "true"                                 => :boolean,
      "false"                                => :boolean,
      "TRUE"                                 => :boolean,
      "v1"                                   => :version,
      "v2.0.1"                               => :version,
      "v1.2.3-beta"                          => :version,
      "vNext"                                => :literal,
      "1.2.3"                                => :opaque_id,
      "en-US"                                => :locale,
      "fr_CA"                                => :locale,
      "zh-Hant"                              => :locale,
      "en"                                   => :locale,
      "fr"                                   => :locale,
      "if"                                   => :literal,
      "to"                                   => :literal,
      "USD"                                  => :currency,
      "eur"                                  => :currency,
      "FAQ"                                  => :literal,
      "2026"                                 => :integer,
      "1999"                                 => :integer,
      "1800"                                 => :integer,
      "2200"                                 => :integer,
      "by-locale"                            => :slug,
      "+15551234567"                         => :phone,
      "+1 (555) 123-4567"                    => :phone,
      "+44 20 7946 0958"                     => :phone,
      "+1"                                   => :literal,
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.dQw4w9WgXcQ" => :jwt,
      "image/png"                            => :mime,
      "application/vnd.api+json"             => :mime,
      "text/html"                            => :mime,
      "foo.com/bar"                          => :url,
      "sub.foo.com/"                         => :url,
      "image.png"                            => :file,
      "report.pdf"                           => :file,
      "data.csv"                             => :file,
      "user-photo.jpg"                       => :file,
      "archive.tar.gz"                       => :file,
      "no-known-ext.qwerty"                  => :opaque_id,
      "1.2.3"                                => :opaque_id,
      "555-666-7777"                         => :phone,
      "(555) 666-7777"                       => :phone,
      "555.666.7777"                         => :phone,
      "123-456-7890"                         => :slug,
      "100-200-3000"                         => :slug,
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
      expect(classifier.variable?(:integer)).to be true
      expect(classifier.variable?(:uuid)).to be true
    end
  end
end
