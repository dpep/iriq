require "set"

module Iriq
  # Heuristic classifier for individual path segments and query values.
  #
  # Returns a symbol from the known TYPES set. Order matters: the first
  # matching rule wins.
  class SegmentClassifier
    # `:number` is a corpus-only umbrella surfaced by Cluster#param_type
    # when both `:integer` and `:float` are observed at the same position
    # without either hitting a clear majority. The classifier never returns
    # `:number` for an individual value — every value is unambiguously one
    # or the other.
    #
    # `:enum` is similarly corpus-only — it surfaces when a position has a
    # bounded set of distinct values observed across enough samples (see
    # Cluster::ENUM_* thresholds).
    TYPES = %i[literal integer float number uuid date year timestamp hash slug
               ipv4 ipv6 url email boolean version locale currency enum opaque_id].freeze

    UUID_RE      = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/.freeze
    INTEGER_RE   = /\A\d+\z/.freeze
    # A float requires a decimal point and digits on both sides. Sign is
    # optional. Bare integers and 4+ char hex/UUID-shaped tokens fall through
    # to their own rules.
    FLOAT_RE     = /\A-?\d+\.\d+\z/.freeze
    # Date formats we'll canonicalize. Deliberately conservative — we only
    # accept forms where the year position is unambiguous (so DD/MM/YYYY is
    # NOT recognized; we can't tell it apart from MM/DD/YYYY from the segment
    # alone). The slash forms only occur in query-param values — URL path
    # separators rule them out for path segments.
    DATE_RE         = /\A\d{4}-\d{2}-\d{2}\z/.freeze
    DATE_SLASH_RE   = %r{\A\d{4}/\d{2}/\d{2}\z}.freeze
    DATE_US_RE      = %r{\A(\d{1,2})/(\d{1,2})/(\d{4})\z}.freeze
    DATE_COMPACT_RE = /\A\d{8}\z/.freeze
    ISO_TIME_RE     = /\A\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+\-]\d{2}:?\d{2})?\z/.freeze
    HASH_RE      = /\A\h{32,}\z/.freeze
    SLUG_RE      = /\A[a-z0-9]+(?:[-_][a-z0-9]+)+\z/.freeze
    LITERAL_RE   = /\A[\p{L}][\p{L}\p{M}_]*\z/u.freeze
    OPAQUE_RE    = /\A[A-Za-z0-9_\-.~]{4,}\z/.freeze

    # Dotted-quad shape; per-octet bounds are validated in classify_ipv4.
    IPV4_RE  = /\A\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\z/.freeze
    # IPv6: matches either the full eight-group form (`a:b:c:d:e:f:g:h`)
    # or any compressed form containing `::`. Rejects bare hex / integers
    # / single-colon strings so we don't shadow :integer, :hash, etc.
    # Doesn't accept IPv4-mapped variants (`::ffff:192.0.2.1`) — common
    # IPv6 traffic in URLs doesn't use them.
    IPV6_RE  = /\A(?:[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4}){7}|(?=[0-9a-fA-F:]*::)[0-9a-fA-F:]{2,})\z/.freeze
    # URL-as-value: a scheme prefix followed by something non-empty.
    # Used for query params like ?redirect=https://foo.com/bar.
    URL_RE   = %r{\A[a-zA-Z][a-zA-Z0-9+.\-]*://\S+\z}.freeze
    # Simplified email — local@host.tld, no leading/trailing dots in either
    # part. Not RFC 5322 compliant; covers the common shape.
    EMAIL_RE = /\A[A-Za-z0-9._%+\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)+\z/.freeze

    # Boolean literal — case-insensitive. `0`/`1` look like integers from a
    # single value alone; the corpus's :enum detection picks them up when
    # they appear as a bounded value set on a param.
    BOOLEAN_RE = /\A(?:true|false)\z/i.freeze
    # SemVer-ish version tag with explicit `v` prefix. Without the prefix
    # `1.2.3` looks like a float / opaque blob; the `v` keeps it
    # unambiguous from a single value.
    VERSION_RE = /\Av\d+(?:\.\d+)*(?:[-+][A-Za-z0-9.\-]+)?\z/.freeze
    # BCP 47-ish locale: 2-3 letter language + separator + region/script.
    # We require the separator — bare `en` looks identical to plain
    # literals and we'd over-classify everything.
    LOCALE_RE  = /\A[a-z]{2,3}[-_][A-Za-z][A-Za-z0-9]+\z/.freeze
    # ISO 4217 currency codes — inline allowlist of the ~30 most-used
    # codes covers the long tail of real traffic. Three-letter all-caps
    # strings (`FAQ`, `FOO`) would otherwise leak into the literal type
    # if we relied on shape alone.
    CURRENCY_CODES = %w[
      USD EUR GBP JPY CNY CHF CAD AUD NZD HKD SGD
      INR KRW MXN BRL ZAR SEK NOK DKK PLN CZK HUF
      RUB TRY ILS AED SAR THB IDR PHP VND TWD MYR
      NGN EGP
    ].to_set.freeze
    CURRENCY_RE    = /\A[A-Za-z]{3}\z/.freeze
    # Plausible year — 4-digit integer in the 1900..2100 window. Checked
    # inside classify_integer so we don't shadow shorter / longer ints.
    YEAR_RANGE = 1900..2100

    # Plausible UNIX timestamps (10 digit seconds or 13 digit ms) from
    # roughly 2001 onward.
    TS_SECONDS_RANGE = 1_000_000_000..9_999_999_999
    TS_MILLIS_RANGE  = 1_000_000_000_000..9_999_999_999_999

    # Bounded memoization: classification of a given string is pure, so
    # repeat segments (e.g. /users in countless paths) can be cached. Cap
    # keeps the cache from unbounded growth when inputs are dominated by
    # unique IDs.
    CACHE_MAX = 10_000

    def initialize
      @cache = {}
    end

    def classify(segment)
      return :literal if segment.nil? || segment.empty?

      cached = @cache[segment]
      return cached if cached

      @cache.clear if @cache.size >= CACHE_MAX
      @cache[segment] = compute_classification(segment)
    end

    # Anything except :literal is considered variable for shape/explain.
    def variable?(type)
      type != :literal
    end

    private

    def compute_classification(segment)
      # Network / structured-value types take precedence over the generic
      # OPAQUE_RE catch-all (which would otherwise grab IPv4) and the
      # LITERAL fallback (which today swallows email + URL + IPv6).
      case segment
      when UUID_RE     then :uuid
      when URL_RE      then :url
      when EMAIL_RE    then :email
      when IPV4_RE     then classify_ipv4(segment)
      when IPV6_RE     then :ipv6
      when HASH_RE     then :hash
      when VERSION_RE  then :version
      when BOOLEAN_RE  then :boolean
      when LOCALE_RE   then :locale
      when DATE_RE, DATE_SLASH_RE, DATE_US_RE then :date
      when ISO_TIME_RE then :timestamp
      when INTEGER_RE  then classify_integer(segment)
      when FLOAT_RE    then :float
      when CURRENCY_RE then classify_currency(segment)
      when SLUG_RE     then :slug
      when LITERAL_RE  then :literal
      when OPAQUE_RE   then :opaque_id
      else :literal
      end
    end

    # IPV4_RE only checks shape (1-3 digits between dots). Validate each
    # octet ≤ 255; on failure fall back to :opaque_id so we don't promote
    # garbage like `999.999.999.999` to :ipv4.
    def classify_ipv4(segment)
      return :opaque_id unless segment.split(".").all? { |o| (0..255).cover?(o.to_i) }

      :ipv4
    end

    # Three-letter shape — only call it :currency if it's actually in the
    # ISO 4217 allowlist (case-insensitive). Otherwise fall through to the
    # literal/opaque rules.
    def classify_currency(segment)
      return :currency if CURRENCY_CODES.include?(segment.upcase)
      return :literal if segment.match?(LITERAL_RE)

      :opaque_id
    end

    def classify_integer(segment)
      n = segment.to_i
      return :timestamp if TS_MILLIS_RANGE.cover?(n)
      return :timestamp if TS_SECONDS_RANGE.cover?(n)

      # Plausible YYYYMMDD: 19000101..21001231-ish. We're strict on year to
      # avoid mis-classifying short 8-digit IDs as dates.
      if DATE_COMPACT_RE.match?(segment)
        y = segment[0, 4].to_i
        m = segment[4, 2].to_i
        d = segment[6, 2].to_i
        if y.between?(1900, 2100) && m.between?(1, 12) && d.between?(1, 31)
          return :date
        end
      end

      # 4-digit integer in the plausible-year window. Same caveat as
      # YYYYMMDD: a 4-digit ID happening to fall in this range will
      # also classify as :year; corpus-level type majority will surface
      # mis-classifications.
      return :year if segment.length == 4 && YEAR_RANGE.cover?(n)

      :integer
    end

    public

    # Shared singleton — preferred default for callers that don't bring
    # their own classifier (saves a per-call allocation).
    DEFAULT = new

    # Canonicalize a recognized date string to ISO 8601 (YYYY-MM-DD). Returns
    # nil if the value isn't one of our accepted date forms. Used by --normalize
    # so /events/2024/01/15 and /events/20240115 both render as
    # /events/2024-01-15 in the output.
    def self.canonical_date(value)
      return nil if value.nil?

      case value
      when DATE_RE
        plausible_date?(value[0, 4], value[5, 2], value[8, 2]) ? value : nil
      when DATE_SLASH_RE
        plausible_date?(value[0, 4], value[5, 2], value[8, 2]) ? value.tr("/", "-") : nil
      when DATE_US_RE
        m, d, y = $~[1].rjust(2, "0"), $~[2].rjust(2, "0"), $~[3]
        plausible_date?(y, m, d) ? "#{y}-#{m}-#{d}" : nil
      when DATE_COMPACT_RE
        y, m, d = value[0, 4], value[4, 2], value[6, 2]
        plausible_date?(y, m, d) ? "#{y}-#{m}-#{d}" : nil
      end
    end

    # Quick bounds check on year/month/day — same window the integer-date
    # branch uses. Doesn't validate day-of-month (Feb 30, Apr 31) — that's
    # more nuance than this heuristic warrants.
    def self.plausible_date?(y, m, d)
      yi = y.to_i; mi = m.to_i; di = d.to_i
      yi.between?(1900, 2100) && mi.between?(1, 12) && di.between?(1, 31)
    end
  end
end
