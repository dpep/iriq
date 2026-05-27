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
               ipv4 ipv6 url email boolean version locale currency phone jwt mime
               file http_status enum opaque_id].freeze

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
    # Scheme-less URL — `foo.com/path`, `sub.foo.com/`, etc. Requires a
    # dotted host with a TLD-like suffix (≥2 letters) followed by a slash
    # to disambiguate from filenames like `image.png` or version strings
    # like `1.2.3`.
    SCHEMELESS_URL_RE = %r{\A[a-zA-Z0-9\-]+(?:\.[a-zA-Z0-9\-]+)*\.[a-zA-Z]{2,}/\S*\z}.freeze
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
    # BCP 47-ish locale: 2-3 letter language + separator + 2-4 char region
    # or script. Real-world subtags: ISO 3166-1 region (`US`, `CA`, 2 letters
    # / 3 digits), ISO 15924 script (`Hans`, 4 letters). The bare 2/3-letter
    # case is handled via LOCALE_LANGUAGE_CODES below so we don't
    # over-classify random short words. A trailing helper (classify_locale_pair)
    # also confirms the language portion is in the allowlist — otherwise
    # things like `by-locale` would wrongly promote to :locale.
    LOCALE_RE  = /\A([a-z]{2,3})[-_]([A-Za-z0-9]{2,4})\z/.freeze
    # Inline ISO 639-1 (subset) — the language codes we'll accept as a
    # standalone locale segment. Bare `en` / `fr` / `ja` etc. classify as
    # :locale; tokens not in the list (like the 2-letter literal `to` or
    # `if`) stay as :literal. Curated for the languages that show up in
    # real `?lang=` traffic; expandable as needed.
    LOCALE_LANGUAGE_CODES = %w[
      ar bg bn ca cs da de el en es et fa fi fr gu he hi hr hu id it
      ja ka kk km kn ko lt lv mk ml mr ms my nb nl no pa pl pt ro ru
      sk sl sr sv sw ta te th tl tr uk ur vi zh
    ].to_set.freeze
    # 2 letters only — 3-letter slot is handled by CURRENCY_RE (ISO 4217
    # codes are 3 chars; ISO 639-2 language codes are too, but we don't
    # ship that list and would shadow currencies for ambiguous strings).
    LOCALE_BARE_RE = /\A[a-z]{2}\z/.freeze
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
    # E.164 phone number — leading `+` then 1-3 digit country code, then up
    # to 14 more digits. Allows separators (space, dash, dot, parens) but
    # they don't count toward digit length. A standalone `+15551234567` and
    # `+1 (555) 123-4567` both classify; bare digit blobs without `+`
    # stay as :integer / :opaque_id (too ambiguous from a single value).
    PHONE_RE       = %r{\A\+(?:[ \-.()\d]){7,20}\z}.freeze
    # NANP phone without `+` — `555-666-7777`, `555.666.7777`, `(555) 666-7777`.
    # The area-code + exchange leading-digit constraint (first digit 2-9 in
    # both) is what makes this safe to add without shadowing :integer —
    # bare digit blobs / dotted numerics fall through. Only matches the
    # 10-digit NANP shape; international formats need the explicit `+`.
    PHONE_NANP_RE  = /\A\(?([2-9]\d{2})\)?[ \-.]?([2-9]\d{2})[ \-.]?(\d{4})\z/.freeze
    # JWT: three base64url-encoded segments separated by dots, header
    # starts with `eyJ` (the `{` JSON prefix base64url-encoded).
    JWT_RE         = /\Aey[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\z/.freeze
    # MIME / media type — RFC 2046 top-level types plus a subtype. The
    # subtype side is permissive (letters/digits/+-.) so `application/vnd.api+json`
    # and `image/svg+xml` both match.
    MIME_RE        = %r{\A(?:text|image|video|audio|application|multipart|message|font|model)/[A-Za-z0-9!#$&^_+\-.]+\z}.freeze
    # File — `name.ext` shape where ext is in FILE_EXTENSIONS. The stem
    # can be a slug, opaque-id, or literal; the meaningful signal is the
    # extension. Per-extension grouping (image / document / data / etc.)
    # surfaces via SegmentClassifier.file_kind for verbose displays.
    FILE_RE = /\A([A-Za-z0-9][A-Za-z0-9_\-.~]*)\.([A-Za-z0-9]{1,8})\z/.freeze
    # Allowlist of common file extensions, keyed by kind. The kind is
    # surfaced via file_kind for verbose output; the type itself is just
    # `:file`. Keep this list curated — random 1-8 char endings can shadow
    # legitimate semantic types (`fr_CA.us`, `1.2.3`).
    FILE_EXTENSIONS = {
      image:    %w[png jpg jpeg gif webp svg bmp tiff tif ico avif heic heif],
      document: %w[pdf doc docx xls xlsx ppt pptx odt ods odp rtf epub],
      data:     %w[csv tsv json xml yaml yml parquet sqlite db ndjson jsonl],
      text:     %w[txt md log markdown rst],
      web:      %w[html htm css js mjs cjs ts jsx tsx],
      audio:    %w[mp3 wav ogg flac aac m4a opus],
      video:    %w[mp4 mov avi mkv webm flv wmv m4v],
      archive:  %w[zip tar gz bz2 7z rar xz tgz],
      code:     %w[rb py go java c cc cpp h hpp sh swift kt rs],
    }.freeze
    # Reverse map ext → kind for O(1) lookup. Lowercase keys; classify
    # downcases before consulting.
    FILE_EXTENSION_KIND = FILE_EXTENSIONS.each_with_object({}) { |(kind, exts), h|
      exts.each { |e| h[e] = kind }
    }.freeze

    # HTTP status — bare 3-digit integer in the 100..599 window. Same
    # corpus-promotion pattern as :year: a single 3-digit int is ambiguous,
    # but a position whose values cluster inside the HTTP status window is
    # almost certainly statuses. See Cluster#param_type for the promotion.
    HTTP_STATUS_RANGE = 100..599
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
      when JWT_RE      then :jwt
      when URL_RE      then :url
      when EMAIL_RE    then :email
      when MIME_RE     then :mime
      when SCHEMELESS_URL_RE then :url
      when IPV4_RE     then classify_ipv4(segment)
      when IPV6_RE     then :ipv6
      when HASH_RE     then :hash
      when VERSION_RE  then :version
      when BOOLEAN_RE  then :boolean
      when LOCALE_RE   then classify_locale_pair(segment)
      when LOCALE_BARE_RE then classify_locale(segment)
      when DATE_RE, DATE_SLASH_RE, DATE_US_RE then :date
      when ISO_TIME_RE then :timestamp
      when PHONE_RE        then classify_phone(segment)
      when PHONE_NANP_RE   then :phone
      when INTEGER_RE  then classify_integer(segment)
      when FLOAT_RE    then :float
      when CURRENCY_RE then classify_currency(segment)
      when FILE_RE     then classify_file(segment)
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

    # Validate E.164-shaped phone: count digits (ignoring separators) and
    # ensure between 7 and 15 inclusive. The shape regex permits a wide
    # range — the digit count is the meaningful guardrail.
    def classify_phone(segment)
      digits = segment.count("0-9")
      return :phone if digits.between?(7, 15)

      :opaque_id
    end

    # File classification — only promote when the trailing extension is
    # in the allowlist. Otherwise fall through to the slug/literal/opaque
    # rules so `1.2.3` (version) and `fr_CA.us` (locale-shaped opaque) don't
    # get pulled in by the FILE_RE shape.
    def classify_file(segment)
      ext = segment[/\.([A-Za-z0-9]{1,8})\z/, 1]&.downcase
      return :file if ext && FILE_EXTENSION_KIND.key?(ext)
      return :slug if segment.match?(SLUG_RE)

      :opaque_id
    end

    # Three-letter shape — only call it :currency if it's actually in the
    # ISO 4217 allowlist (case-insensitive). Otherwise fall through to the
    # literal/opaque rules.
    def classify_currency(segment)
      return :currency if CURRENCY_CODES.include?(segment.upcase)
      return :literal if segment.match?(LITERAL_RE)

      :opaque_id
    end

    # Bare 2- or 3-letter lowercase token — only :locale when it's a known
    # ISO 639-1 code. Otherwise it's a regular literal (`if`, `to`, `of`).
    def classify_locale(segment)
      return :locale if LOCALE_LANGUAGE_CODES.include?(segment)

      :literal
    end

    # Dashed/underscored locale form (`en-US`, `zh-Hans`). Only promote to
    # :locale when the language portion is in the ISO 639-1 allowlist —
    # otherwise tokens like `by-locale` would slip through.
    def classify_locale_pair(segment)
      lang = segment[/\A[a-z]{2,3}/]
      return :locale if LOCALE_LANGUAGE_CODES.include?(lang)

      segment.match?(SLUG_RE) ? :slug : :literal
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

      # Plausible-year window detection deliberately doesn't happen here.
      # A single 4-digit int in 1900..2100 is ambiguous (could be a year
      # OR an integer ID). The corpus layer promotes a position to :year
      # via min/max range analysis once it has enough samples — see
      # Cluster#param_type.

      :integer
    end

    public

    # Shared singleton — preferred default for callers that don't bring
    # their own classifier (saves a per-call allocation).
    DEFAULT = new

    # Display name for a type in `--normalize` placeholders. Collapses
    # `:ipv4` and `:ipv6` to `:ip` (callers that want the specific family
    # read it off the classifier directly or via cluster stats).
    def self.display_type(type)
      return :ip if type == :ipv4 || type == :ipv6

      type
    end

    # Return the kind (`:image`/`:document`/`:data`/...) for a file-shaped
    # value, or nil if the value isn't a recognized file. Used by verbose
    # displays to subdivide `:file` without polluting the top-level type
    # taxonomy.
    def self.file_kind(value)
      return nil if value.nil?
      ext = value[/\.([A-Za-z0-9]{1,8})\z/, 1]&.downcase
      ext && FILE_EXTENSION_KIND[ext]
    end

    # Param-name hints — when a value's classifier output is too generic
    # (`:literal`, `:opaque_id`, `:slug`) to be informative, the param name
    # can supply the type. `?phone=unknown` becomes `:phone` even though
    # `unknown` is a literal. Only "safe" string-shaped types are in the
    # map; numeric types (`:integer`, `:year`, `:http_status`) are handled
    # by range analysis instead.
    PARAM_NAME_HINTS = {
      "phone"        => :phone,
      "tel"          => :phone,
      "telephone"    => :phone,
      "mobile"       => :phone,
      "cell"         => :phone,
      "email"        => :email,
      "e_mail"       => :email,
      "mail"         => :email,
      "locale"       => :locale,
      "lang"         => :locale,
      "language"     => :locale,
      "currency"     => :currency,
      "cur"          => :currency,
      "curr"         => :currency,
      "url"          => :url,
      "uri"          => :url,
      "redirect"     => :url,
      "redirect_url" => :url,
      "return_to"    => :url,
      "return_url"   => :url,
      "callback"     => :url,
      "callback_url" => :url,
      "next_url"     => :url,
      "jwt"          => :jwt,
      "bearer"       => :jwt,
      "auth_token"   => :jwt,
      "mime"         => :mime,
      "content_type" => :mime,
      "media_type"   => :mime,
    }.freeze
    # Types the param-name hint is allowed to override. Anything more
    # specific (`:integer`, `:uuid`, etc.) already carries useful info —
    # the classifier wins.
    PARAM_HINT_OVERRIDABLE = %i[literal opaque_id slug].to_set.freeze

    # Return a hinted type for a param name when the resolved value type
    # is generic. Nil when no hint applies. Both Cluster#param_type (for
    # the corpus path) and Normalizer.shape_query (for one-shot rendering)
    # consult this so corpus + one-shot agree on the override.
    def self.param_name_hint(name, current_type)
      return nil if name.nil? || !PARAM_HINT_OVERRIDABLE.include?(current_type)

      PARAM_NAME_HINTS[name.to_s.downcase]
    end

    # Canonicalize a currency code to uppercase ISO 4217. Returns nil if
    # the value isn't a known code. Used by --normalize so /pricing/usd and
    # /pricing/USD both render as /pricing/USD.
    def self.canonical_currency(value)
      return nil if value.nil?
      up = value.upcase
      CURRENCY_CODES.include?(up) ? up : nil
    end

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
