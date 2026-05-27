module Iriq
  # Heuristic classifier for individual path segments and query values.
  #
  # Returns a symbol from the known TYPES set. Order matters: the first
  # matching rule wins.
  class SegmentClassifier
    # `:numeric` is a corpus-only umbrella surfaced by Cluster#param_type
    # when both `:integer_id` and `:float` are observed at the same position
    # without either hitting a clear majority. The classifier never returns
    # `:numeric` for an individual value — every value is unambiguously one
    # or the other.
    TYPES = %i[literal integer_id float numeric uuid date timestamp hash slug
               ipv4 ipv6 url email opaque_id].freeze

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
    # / single-colon strings so we don't shadow :integer_id, :hash, etc.
    # Doesn't accept IPv4-mapped variants (`::ffff:192.0.2.1`) — common
    # IPv6 traffic in URLs doesn't use them.
    IPV6_RE  = /\A(?:[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4}){7}|(?=[0-9a-fA-F:]*::)[0-9a-fA-F:]{2,})\z/.freeze
    # URL-as-value: a scheme prefix followed by something non-empty.
    # Used for query params like ?redirect=https://foo.com/bar.
    URL_RE   = %r{\A[a-zA-Z][a-zA-Z0-9+.\-]*://\S+\z}.freeze
    # Simplified email — local@host.tld, no leading/trailing dots in either
    # part. Not RFC 5322 compliant; covers the common shape.
    EMAIL_RE = /\A[A-Za-z0-9._%+\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)+\z/.freeze

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
      when DATE_RE, DATE_SLASH_RE, DATE_US_RE then :date
      when ISO_TIME_RE then :timestamp
      when INTEGER_RE  then classify_integer(segment)
      when FLOAT_RE    then :float
      when HASH_RE     then :hash
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

      :integer_id
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
