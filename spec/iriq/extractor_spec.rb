describe Iriq::Extractor do
  subject(:extractor) { described_class.new }

  def extract(text)
    extractor.extract(text).map(&:canonical)
  end

  describe "empty input" do
    it "returns [] for nil" do
      expect(extract(nil)).to eq([])
    end

    it "returns [] for empty string" do
      expect(extract("")).to eq([])
    end

    it "returns [] for text with no URLs" do
      expect(extract("just some prose, no URLs here")).to eq([])
    end
  end

  describe "basic URLs" do
    it "extracts a single http URL" do
      expect(extract("Visit http://foo.com today")).to eq(["http://foo.com"])
    end

    it "extracts a single https URL" do
      expect(extract("Visit https://foo.com today")).to eq(["https://foo.com"])
    end

    it "extracts ftp and ws/wss URLs" do
      expect(extract("ftp://files.example.com and wss://chat.example.com"))
        .to eq(["ftp://files.example.com", "wss://chat.example.com"])
    end

    it "extracts multiple URLs in source order" do
      expect(extract("First https://a.com then https://b.com and https://c.com"))
        .to eq(["https://a.com", "https://b.com", "https://c.com"])
    end
  end

  describe "URNs" do
    it "extracts a urn:isbn" do
      expect(extract("See urn:isbn:0451450523 for details")).to eq(["urn:isbn:0451450523"])
    end

    it "extracts a urn:uuid" do
      expect(extract("Session urn:uuid:f47ac10b-58cc-4372-a567-0e02b2c3d479 expired"))
        .to eq(["urn:uuid:f47ac10b-58cc-4372-a567-0e02b2c3d479"])
    end
  end

  describe "trailing sentence punctuation" do
    it "trims a trailing period" do
      expect(extract("Visit https://foo.com.")).to eq(["https://foo.com"])
    end

    it "trims a trailing comma" do
      expect(extract("https://foo.com, and then more")).to eq(["https://foo.com"])
    end

    it "trims trailing exclamation" do
      expect(extract("Look at https://foo.com!")).to eq(["https://foo.com"])
    end

    it "trims trailing question mark" do
      expect(extract("Did you see https://foo.com?")).to eq(["https://foo.com"])
    end

    it "trims trailing semicolon" do
      expect(extract("https://foo.com; next thing")).to eq(["https://foo.com"])
    end

    it "trims multiple combined trailing chars" do
      expect(extract('"https://foo.com",')).to eq(["https://foo.com"])
    end
  end

  describe "balanced vs unbalanced parens/brackets" do
    it "preserves balanced parens inside the URL" do
      expect(extract("See https://en.wikipedia.org/wiki/Ruby_(programming_language)"))
        .to eq(["https://en.wikipedia.org/wiki/Ruby_(programming_language)"])
    end

    it "trims an outer unbalanced closing paren" do
      expect(extract("(see https://foo.com)")).to eq(["https://foo.com"])
    end

    it "trims an outer unbalanced closing bracket" do
      expect(extract("[https://foo.com]")).to eq(["https://foo.com"])
    end

    it "handles nested parens correctly" do
      expect(extract("(see https://en.wikipedia.org/wiki/Foo_(bar))"))
        .to eq(["https://en.wikipedia.org/wiki/Foo_(bar)"])
    end
  end

  describe "quotes and brackets as boundaries" do
    it 'stops at a double quote' do
      expect(extract('href="https://foo.com"')).to eq(["https://foo.com"])
    end

    it "stops at a single quote" do
      expect(extract("href='https://foo.com'")).to eq(["https://foo.com"])
    end

    it "stops at backtick" do
      expect(extract("`https://foo.com`")).to eq(["https://foo.com"])
    end

    it "stops at angle brackets (markdown autolink)" do
      expect(extract("<https://foo.com>")).to eq(["https://foo.com"])
    end

    it "extracts from JSON-shaped text" do
      expect(extract(%({"url":"https://foo.com/x?a=1"}))).to eq(["https://foo.com/x?a=1"])
    end
  end

  describe "markdown" do
    it "extracts URL from [text](url) link" do
      expect(extract("[Foo](https://foo.com)")).to eq(["https://foo.com"])
    end

    it "extracts URL from reference-style [text](url 'title')" do
      expect(extract("[Foo](https://foo.com 'Title')")).to eq(["https://foo.com"])
    end
  end

  describe "word-boundary safety" do
    it "does not match a URL stuck to a preceding word" do
      expect(extract("seehttps://foo.com")).to eq([])
    end

    it "does not match a URL stuck to a preceding path char" do
      expect(extract("/path/tohttps://foo.com")).to eq([])
    end

    it "matches a URL after punctuation that isn't a word char" do
      expect(extract(":https://foo.com")).to eq(["https://foo.com"])
    end
  end

  describe "complex URLs" do
    it "handles port + query + fragment" do
      expect(extract("https://foo.com:8443/x?a=1&b=2#top"))
        .to eq(["https://foo.com:8443/x?a=1&b=2#top"])
    end

    it "MVP limitation: a comma in a URL is treated as a boundary (truncates the URL)" do
      # Trade-off: free-text extraction is more reliable when comma is a
      # boundary (CSV-style text splits correctly); the cost is that
      # comma-bearing query strings like `/?q=37.7,-122.4` get truncated.
      expect(extract("https://maps.example.com/?q=37.7,-122.4 next"))
        .to eq(["https://maps.example.com/?q=37.7"])
    end
  end

  describe "Unicode IRIs" do
    it "extracts an IRI with Unicode host" do
      expect(extract("Visit https://例え.テスト/こんにちは today"))
        .to eq(["https://例え.テスト/こんにちは"])
    end
  end

  describe "smart quotes (curly)" do
    it "trims trailing curly quotes" do
      expect(extract("She said “https://foo.com” loudly"))
        .to eq(["https://foo.com"])
    end
  end

  describe "across newlines and multi-paragraph text" do
    it "extracts URLs from multi-line text" do
      text = <<~TXT
        Some preamble.

        - https://a.com
        - https://b.com (with note)
        - [Markdown link](https://c.com)
        - <https://d.com>
        - urn:isbn:0451450523

        Closing thoughts about https://e.com.
      TXT
      expect(extract(text)).to eq(%w[
        https://a.com
        https://b.com
        https://c.com
        https://d.com
        urn:isbn:0451450523
        https://e.com
      ])
    end
  end

  describe "false positives" do
    it "does not extract bare 'foo.com' (scheme-less skipped intentionally)" do
      expect(extract("visit foo.com today")).to eq([])
    end

    it "does not extract local paths" do
      expect(extract("see ./README.md and /usr/local/bin")).to eq([])
    end

    it "does not extract from text resembling a URL but missing scheme" do
      expect(extract("user@host:port/path")).to eq([])
    end
  end

  describe "trickier corner cases" do
    it "is case-insensitive on the scheme" do
      expect(extract("Visit HTTPS://Foo.com/x")).to eq(["https://foo.com/x"])
    end

    it "extracts adjacent URLs separated by a period (likely sentence join)" do
      # Best-effort: a `.` immediately followed by another URL is rare prose
      # and the trailing-trim should still leave both extractable.
      expect(extract("First https://a.com. Second https://b.com."))
        .to eq(["https://a.com", "https://b.com"])
    end

    it "does not extract a bare email address" do
      expect(extract("contact user@example.com today")).to eq([])
    end

    it "does not extract mailto: (not in our scheme allow-list)" do
      expect(extract("write to mailto:user@example.com")).to eq([])
    end

    it "extracts a URL ending in slash (canonical drops the trailing /)" do
      # Iriq's canonical form normalizes an empty-path "/" away; both
      # `https://foo.com` and `https://foo.com/` are equivalent per RFC 3986.
      expect(extract("at https://foo.com/")).to eq(["https://foo.com"])
    end

    it "preserves dots inside the path/file" do
      expect(extract("Read https://foo.com/file.txt right now"))
        .to eq(["https://foo.com/file.txt"])
    end

    it "trims only the sentence period, leaving filename intact" do
      expect(extract("Read https://foo.com/file.txt.")).to eq(["https://foo.com/file.txt"])
    end

    it "extracts URLs with percent-encoded characters" do
      expect(extract("see https://foo.com/path%20with%20spaces today"))
        .to eq(["https://foo.com/path%20with%20spaces"])
    end

    it "handles deeply nested subdomains" do
      expect(extract("https://a.b.c.d.foo.com/x"))
        .to eq(["https://a.b.c.d.foo.com/x"])
    end

    it "handles markdown link with title quote" do
      expect(extract(%([Foo](https://foo.com "title goes here"))))
        .to eq(["https://foo.com"])
    end

    it "extracts URL with non-default port and an empty path" do
      expect(extract("ws on wss://chat.example.com:9001")).to eq(["wss://chat.example.com:9001"])
    end

    it "handles two URLs inside one set of parens" do
      expect(extract("(https://a.com or https://b.com)"))
        .to eq(["https://a.com", "https://b.com"])
    end

    it "handles mismatched bracket on the outside" do
      expect(extract("[https://foo.com)")).to eq(["https://foo.com"])
    end

    it "drops the broken half of a URL split across a newline" do
      # \n is whitespace; the URL stops at it. The second line isn't a valid URL.
      expect(extract("https://\nfoo.com")).to eq([])
    end

    it "preserves Unicode in the path even with surrounding prose" do
      expect(extract("「https://例え.テスト/こんにちは」を見て"))
        .to eq(["https://例え.テスト/こんにちは"])
    end

    it "extracts a URN with fragment-like NSS" do
      expect(extract("DOI urn:doi:10.1000/xyz#section here"))
        .to eq(["urn:doi:10.1000/xyz#section"])
    end

    it "doesn't crash on input that's literally a scheme prefix with nothing after" do
      expect(extract("https://")).to eq([])
    end

    it "handles a URL immediately followed by code-fence backtick" do
      expect(extract("`https://foo.com`")).to eq(["https://foo.com"])
    end
  end

  describe "iteration 3 — adversarial" do
    it "stops at a possessive apostrophe" do
      expect(extract("https://foo.com's API is great")).to eq(["https://foo.com"])
    end

    it "handles a URL at the very start of text" do
      expect(extract("https://foo.com is the site")).to eq(["https://foo.com"])
    end

    it "handles a URL at the very end of text with no punctuation" do
      expect(extract("Great site: https://foo.com")).to eq(["https://foo.com"])
    end

    it "extracts an IPv4 URL" do
      expect(extract("local: https://127.0.0.1:8080/x")).to eq(["https://127.0.0.1:8080/x"])
    end

    it "extracts URLs cleanly from CSV-shaped text" do
      expect(extract("1,https://a.com,2,https://b.com,3"))
        .to eq(["https://a.com", "https://b.com"])
    end

    it "handles unbalanced trailing paren preceded by balanced inner pair" do
      # Inner ( and ) balance; outer ) is unbalanced and trimmed.
      expect(extract("(https://foo.com/Foo_(bar))")).to eq(["https://foo.com/Foo_(bar)"])
    end

    it "extracts a Cyrillic IRI" do
      expect(extract("Сайт https://россия.рф/о-нас здесь"))
        .to eq(["https://россия.рф/о-нас"])
    end


    it "doesn't extract from word-joined text that happens to contain a URL" do
      expect(extract("textseehttps://foo.com")).to eq([])
    end

    it "extracts both URLs even with mixed brackets and punctuation around them" do
      text = '<<see [https://a.com] and (https://b.com)!>>'
      expect(extract(text)).to eq(["https://a.com", "https://b.com"])
    end
  end

  describe "scheme-less mode (opt-in)" do
    let(:permissive) { described_class.new(scheme_less: true) }

    def permissive_extract(text)
      permissive.extract(text).map(&:canonical)
    end

    it "is off by default" do
      expect(extract("visit foo.com/users today")).to eq([])
    end

    it "extracts scheme-less URLs with a path on an allow-listed TLD" do
      expect(permissive_extract("visit foo.com/users today"))
        .to eq(["https://foo.com/users"])
    end

    it "requires a path — bare 'foo.com' still skipped" do
      expect(permissive_extract("visit foo.com today")).to eq([])
    end

    it "rejects TLDs not in the allow-list" do
      expect(permissive_extract("visit foo.xyz/path today")).to eq([])
    end

    it "supports multiple common TLDs" do
      result = permissive_extract("a.com/x and b.org/y and c.ai/z")
      expect(result).to eq(["https://a.com/x", "https://b.org/y", "https://c.ai/z"])
    end

    it "doesn't extract from an email address (avoids user@foo.com)" do
      expect(permissive_extract("contact user@foo.com/path today")).to eq([])
    end

    it "still extracts explicit-scheme URLs alongside scheme-less ones" do
      result = permissive_extract("see https://a.com or just b.com/x next")
      expect(result).to eq(["https://a.com", "https://b.com/x"])
    end

    it "trims trailing punctuation on scheme-less matches" do
      expect(permissive_extract("hit foo.com/x.")).to eq(["https://foo.com/x"])
    end

    it "preserves source order across scheme + scheme-less matches" do
      result = permissive_extract("first b.com/x then https://a.com last c.org/y")
      expect(result).to eq(["https://b.com/x", "https://a.com", "https://c.org/y"])
    end
  end

  describe "duplicates and ordering" do
    it "extract returns duplicates in source order" do
      expect(extract("https://a.com then https://a.com again")).to eq([
        "https://a.com", "https://a.com",
      ])
    end

    it "extract_strings deduplicates while preserving first-seen order" do
      result = extractor.extract_strings("https://b.com first then https://a.com then https://b.com again")
      expect(result).to eq(["https://b.com", "https://a.com"])
    end
  end
end
