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
    # Cluster::ENUM_* thresholds). `:string` is the rung below `:enum`: a
    # param that varies across free-form literal values but isn't a confident
    # bounded set yet. Neither is ever returned for a single value.
    TYPES = %i[literal string integer float number uuid date year timestamp hash slug
               ipv4 ipv6 url email boolean version locale currency phone jwt mime
               file color coordinate country base64 http_status enum opaque_id].freeze

    # A float requires a decimal point and digits on both sides. Sign is
    # optional. Bare integers and 4+ char hex/UUID-shaped tokens fall through
    # to their own rules.
    FLOAT_RE     = /\A-?\d+\.\d+\z/.freeze
    # ISO 8601 timestamp shapes (RFC 3339-ish). Date-only forms live on
    # Recognizers::Date / Recognizers::Integer.
    ISO_TIME_RE  = /\A\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+\-]\d{2}:?\d{2})?\z/.freeze
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
      web:      %w[html htm css js mjs cjs ts jsx tsx map],
      font:     %w[woff woff2 ttf otf eot],
      audio:    %w[mp3 wav ogg flac aac m4a opus],
      video:    %w[mp4 mov avi mkv webm flv wmv m4v m3u8],
      archive:  %w[zip tar gz bz2 7z rar xz tgz],
      code:     %w[rb py go java c cc cpp h hpp sh swift kt rs],
    }.freeze
    # Reverse map ext → kind for O(1) lookup. Lowercase keys; classify
    # downcases before consulting.
    FILE_EXTENSION_KIND = FILE_EXTENSIONS.each_with_object({}) { |(kind, exts), h|
      exts.each { |e| h[e] = kind }
    }.freeze

    # Hex color — `#fff`, `#ffffff`, `#ffffff80` (with alpha). 3/4/6/8
    # hex chars after the leading `#`. Other color formats (named, rgb(),
    # hsl()) aren't recognized yet; this is the only one common in URL
    # path/query positions.
    COLOR_HEX_RE = /\A#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})\z/.freeze
    # Coordinate pair — `lat,lng`, both signed decimals. The extractor's
    # comma boundary means this only survives when present at classify
    # time (e.g. query values fed in already-parsed). Each component
    # validated for plausible lat/lng range in classify_coordinate.
    COORDINATE_RE = /\A(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)\z/.freeze
    # ISO 3166-1 alpha-2 — 2 letters, validated against the inline
    # allowlist below (so random 2-letter uppercase tokens like `OK` or
    # `NO` don't unconditionally promote). Lowercase tokens are routed
    # through :locale by LOCALE_BARE_RE.
    COUNTRY_RE = /\A[A-Z]{2}\z/.freeze
    COUNTRY_CODES = %w[
      AD AE AF AG AL AM AO AR AT AU AZ
      BA BB BD BE BG BH BJ BM BN BO BR BS BT BW BY BZ
      CA CD CG CH CI CL CM CN CO CR CU CY CZ
      DE DJ DK DM DO DZ
      EC EE EG ER ES ET
      FI FJ FK FM FO FR
      GA GB GE GH GI GL GM GN GR GT GU GW GY
      HK HN HR HT HU
      ID IE IL IM IN IQ IR IS IT
      JM JO JP
      KE KG KH KM KN KP KR KW KY KZ
      LA LB LC LI LK LR LS LT LU LV LY
      MA MC MD ME MG MK ML MM MN MO MR MT MU MV MW MX MY MZ
      NA NE NG NI NL NO NP NR NU NZ
      OM
      PA PE PF PG PH PK PL PR PT PW PY
      QA
      RE RO RS RU RW
      SA SB SC SD SE SG SI SK SL SM SN SO SR SS ST SV SY SZ
      TD TG TH TJ TM TN TO TR TT TV TW TZ
      UA UG US UY UZ
      VA VC VE VG VI VN VU
      WS
      YE
      ZA ZM ZW
    ].to_set.freeze
    # Standard base64 — at least 16 chars, made up of base64 alphabet,
    # AND contains one of the disambiguating chars (`+`, `/`, trailing
    # `=` padding) so we don't shadow plain alphanumeric :opaque_id
    # blobs. URL-safe base64 (which uses `-`/`_`) overlaps too heavily
    # with :slug to discriminate from shape alone.
    BASE64_RE = %r{\A[A-Za-z0-9+/]{16,}={0,2}\z}.freeze

    # HTTP status — bare 3-digit integer in the 100..599 window. Same
    # corpus-promotion pattern as :year: a single 3-digit int is ambiguous,
    # but a position whose values cluster inside the HTTP status window is
    # almost certainly statuses. See Cluster#param_type for the promotion.
    HTTP_STATUS_RANGE = 100..599
    # Plausible year — 4-digit integer in the 1900..2100 window. Checked
    # inside classify_integer so we don't shadow shorter / longer ints.
    YEAR_RANGE = 1900..2100

    # Bounded memoization: classification of a given string is pure, so
    # repeat segments (e.g. /users in countless paths) can be cached. Cap
    # keeps the cache from unbounded growth when inputs are dominated by
    # unique IDs.
    CACHE_MAX = 10_000

    def initialize
      @cache = {}
      # The recognizer ensemble consulted at classify time. Starts with
      # the built-in three (uuid, date, integer); Corpus#activate_proposal
      # appends SynthesizedRecognizer instances at runtime so a corpus
      # picks up its learned patterns without classifier surgery.
      @recognizers = [Recognizers::UUID, Recognizers::DATE, Recognizers::INTEGER]
    end

    def classify(segment)
      return :literal if segment.nil? || segment.empty?

      cached = @cache[segment]
      return cached if cached

      @cache.clear if @cache.size >= CACHE_MAX
      @cache[segment] = compute_classification(segment)
    end

    # Append a Recognizer to the ensemble. Called by Corpus#activate_proposal
    # to promote a learned RecognizerProposal into a live Recognizer.
    # Busts the classify cache so subsequent classify() calls see the
    # new Recognizer.
    def register_recognizer(recognizer)
      @recognizers << recognizer
      @cache.clear
      recognizer
    end

    # Snapshot of the live ensemble. Useful for tests and tooling that
    # want to inspect which Recognizers a corpus is consulting.
    def recognizers
      @recognizers.dup
    end

    # Anything except :literal is considered variable for shape/explain.
    def variable?(type)
      type != :literal
    end

    private

    def compute_classification(segment)
      # Cheap composition checks short-circuit regex matches that can't
      # possibly fire. Each `_RE` test below is preceded by a `String#include?`
      # / `start_with?` / `size` guard so a literal like "users" walks
      # past 20-odd `_RE`s in O(len) instead of O(len * n_regexes).
      size      = segment.size
      first     = segment.getbyte(0)
      digit0    = first && first >= 0x30 && first <= 0x39
      has_dash  = segment.include?("-")
      has_dot   = segment.include?(".")
      has_colon = segment.include?(":")
      has_slash = segment.include?("/")
      has_at    = segment.include?("@")
      has_sep   = has_dash || segment.include?("_")
      has_comma = segment.include?(",")

      # Scored ensemble over the live Recognizer list — built-ins +
      # anything Corpus#activate_proposal has registered for this
      # classifier instance.
      if (v = Recognizer.ensemble(segment, @recognizers))
        return v[:type]
      end

      # Network / structured-value types take precedence over the generic
      # OPAQUE_RE catch-all (which would otherwise grab IPv4) and the
      # LITERAL fallback (which today swallows email + URL + IPv6).
      return :jwt                  if segment.start_with?("ey") && segment.count(".") == 2 && JWT_RE.match?(segment)
      return classify_color(segment) if first == 0x23 && COLOR_HEX_RE.match?(segment)  # '#'
      return :url                  if has_colon && segment.include?("://") && URL_RE.match?(segment)
      return :email                if has_at && EMAIL_RE.match?(segment)
      return :mime                 if has_slash && MIME_RE.match?(segment)
      return :url                  if has_dot && has_slash && SCHEMELESS_URL_RE.match?(segment)
      return classify_ipv4(segment) if digit0 && has_dot && IPV4_RE.match?(segment)
      return :ipv6                 if has_colon && IPV6_RE.match?(segment)
      return classify_coordinate(segment) if has_comma && COORDINATE_RE.match?(segment)
      return :hash                 if size >= 32 && HASH_RE.match?(segment)
      return :version              if first == 0x76 && VERSION_RE.match?(segment) # 'v'
      return :boolean              if (size >= 4 && size <= 5) && BOOLEAN_RE.match?(segment)
      return classify_locale_pair(segment) if has_sep && LOCALE_RE.match?(segment)
      return classify_locale(segment) if size == 2 && LOCALE_BARE_RE.match?(segment)
      return :timestamp            if has_colon && ISO_TIME_RE.match?(segment)
      return classify_phone(segment) if first == 0x2B && PHONE_RE.match?(segment)  # '+'
      return :phone                if (has_dash || has_dot || segment.include?("(")) && PHONE_NANP_RE.match?(segment)
      return :float                if has_dot && FLOAT_RE.match?(segment)
      return classify_currency(segment) if size == 3 && CURRENCY_RE.match?(segment)
      return classify_country(segment)  if size == 2 && COUNTRY_RE.match?(segment)
      return :base64                    if size >= 16 && (segment.include?("=") || segment.include?("+") || segment.include?("/")) && BASE64_RE.match?(segment)
      return classify_file(segment) if has_dot && FILE_RE.match?(segment)
      return :slug                 if has_sep && SLUG_RE.match?(segment)
      return :literal              if LITERAL_RE.match?(segment)
      return :opaque_id            if OPAQUE_RE.match?(segment)

      :literal
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

    # Color — only the hex form is recognized for now. Returns :color
    # when the value matches COLOR_HEX_RE. Future extensions (named
    # colors, rgb(), hsl()) can plug in via classify_color without
    # rearranging compute_classification.
    def classify_color(segment)
      return :color if COLOR_HEX_RE.match?(segment)

      :opaque_id
    end

    # Coordinate pair — both numbers must land in plausible lat/lng
    # bounds: latitude ±90, longitude ±180. We accept either ordering
    # (lat,lng OR lng,lat) by checking both. Pairs outside the range
    # fall back to :opaque_id so generic CSV-shaped values aren't
    # promoted.
    def classify_coordinate(segment)
      m = segment.match(COORDINATE_RE) or return :opaque_id
      a = m[1].to_f
      b = m[2].to_f
      if (a.between?(-90, 90) && b.between?(-180, 180)) ||
         (a.between?(-180, 180) && b.between?(-90, 90))
        return :coordinate
      end

      :opaque_id
    end

    # Country — promote to :country only when the 2-letter token is in
    # the ISO 3166-1 alpha-2 allowlist. Otherwise fall through to
    # :literal (matches LITERAL_RE).
    def classify_country(segment)
      return :country if COUNTRY_CODES.include?(segment)

      :literal
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

    # Return the kind (`:hex` for now — placeholder for future named /
    # rgb / hsl support) of a color-shaped value, or nil if the value
    # isn't a recognized color. Used by verbose displays alongside the
    # `:color` type itself.
    def self.color_kind(value)
      return nil if value.nil?
      return :hex if COLOR_HEX_RE.match?(value)

      nil
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
      "color"        => :color,
      "colour"       => :color,
      "bg"           => :color,
      "background"   => :color,
      "fg"           => :color,
      "foreground"   => :color,
      "coords"       => :coordinate,
      "coordinates"  => :coordinate,
      "geo"          => :coordinate,
      "location"     => :coordinate,
      "position"     => :coordinate,
      "latlng"       => :coordinate,
      "latlon"       => :coordinate,
      "country"      => :country,
      "country_code" => :country,
      "nation"       => :country,
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
      return nil unless value.is_a?(String)

      canon = Recognizers::Date.canonical(value)
      return canon if canon

      # Compact YYYYMMDD lives on the Integer recognizer for classification,
      # but the canonical form is part of the same date family.
      if Recognizers::Integer::COMPACT_DATE_PATTERN.match?(value)
        y, m, d = value[0, 4], value[4, 2], value[6, 2]
        return "#{y}-#{m}-#{d}" if Recognizers::Date.plausible?(y, m, d)
      end

      nil
    end
  end
end
