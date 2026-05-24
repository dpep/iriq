module Iriq
  # Pulls IRIs out of free text. Scheme-anchored — only URLs whose scheme
  # appears explicitly are extracted (scheme-less hosts like "foo.com/x" are
  # too noisy to disambiguate from prose).
  #
  #   Iriq::Extractor.new.extract("Visit https://foo.com today.")
  #   # => [#<Iriq::Identifier https://foo.com>]
  #
  # Design draws on twitter-text and GFM autolink rules: scheme anchoring,
  # iterative trailing-punct trim, balanced-paren preservation.
  class Extractor
    SCHEMES = %w[https http ftp wss ws].freeze

    # Conservative TLD allow-list for scheme-less extraction. Limited to a
    # small set of very common TLDs to keep false-positive rate low. A
    # scheme-less candidate ALSO requires a `/path` to count, so plain
    # `foo.com` in prose still won't match — only `foo.com/something`.
    SCHEMELESS_TLDS = %w[com org net io ai dev co app gov edu].freeze

    # Boundary chars — a URL ends at any of these (whitespace, angle
    # brackets, quotes, backtick).
    BOUNDARY = %r{[\s<>"'`]}.freeze

    # Non-ASCII Unicode brackets and quotation marks that almost always
    # terminate a URL in source text (e.g. `「URL」`). ASCII brackets are NOT
    # listed here — those stay inside the URL match so the balanced-paren
    # trim step can handle them (Wikipedia URLs like /Foo_(bar) survive).
    NON_ASCII_BOUNDARY = (
      "」』）】〉》〕〗〙〛｠｝］＞" +  # CJK closing brackets
      "「『（【〈《〔〖〘〚｟｛［＜" +  # CJK opening brackets
      "“”‘’„‟‚«»‹›"                 # Unicode quotation marks
    ).chars.uniq.join.freeze

    URL_CHAR_CLASS = %{[^\\s<>"'`,#{NON_ASCII_BOUNDARY}]+}.freeze

    CANDIDATE_RE = %r{
      (?<![\w/])                                                    # not mid-word, not mid-path
      (?:
        (?i:#{SCHEMES.join("|")})://#{URL_CHAR_CLASS}               # absolute URL
        |
        urn:[a-zA-Z0-9][a-zA-Z0-9\-]{0,30}:#{URL_CHAR_CLASS}        # urn:NID:NSS
      )
    }xu.freeze

    # Scheme-less pattern: opt-in, conservative. Requires a host whose TLD
    # is in SCHEMELESS_TLDS AND a `/path` to disambiguate from prose. The
    # host part allows ASCII labels separated by dots; no Unicode hosts
    # (those are too easily confused with prose).
    SCHEMELESS_RE = %r{
      (?<![\w/.@])                                                   # boundary; not after @ (avoid emails)
      (?:[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+            # label(s)
      (?i:#{SCHEMELESS_TLDS.join("|")})                              # TLD
      /#{URL_CHAR_CLASS}                                             # required path
    }xu.freeze

    # Punctuation that's almost always sentence punctuation rather than part
    # of a URL when it appears at the trailing edge.
    TRAILING_PUNCT_RE = /[.,;:!?'"‘’“”]+\z/u.freeze

    # Unmatched closing brackets that should be trimmed.
    BRACKET_PAIRS = { ")" => "(", "]" => "[", "}" => "{" }.freeze

    def initialize(scheme_less: true)
      @scheme_less = scheme_less
    end

    def extract(text)
      return [] if text.nil? || text.empty?

      candidates = scan_candidates(text)
      candidates.filter_map do |candidate|
        trimmed = trim(candidate)
        next nil if trimmed.empty?

        begin
          Parser.parse(trimmed)
        rescue ParseError
          nil
        end
      end
    end

    # Same as extract but returns only canonical strings, deduplicated,
    # preserving first-seen order.
    def extract_strings(text)
      seen = {}
      extract(text).each { |iri| seen[iri.canonical] ||= true }
      seen.keys
    end

    private

    # Combine scheme + (optionally) scheme-less matches in source order.
    def scan_candidates(text)
      matches = []
      text.scan(CANDIDATE_RE) { matches << [Regexp.last_match.begin(0), Regexp.last_match[0]] }
      if @scheme_less
        text.scan(SCHEMELESS_RE) { matches << [Regexp.last_match.begin(0), Regexp.last_match[0]] }
      end
      matches.sort_by(&:first).map(&:last)
    end

    # Iteratively strip sentence punctuation and unmatched closing brackets
    # until the candidate stabilizes.
    def trim(candidate)
      s = candidate.dup
      loop do
        before = s
        s = s.sub(TRAILING_PUNCT_RE, "")
        BRACKET_PAIRS.each do |close, open|
          while s.end_with?(close) && s.count(close) > s.count(open)
            s = s[0...-1]
          end
        end
        break if s == before
      end
      s
    end
  end
end
