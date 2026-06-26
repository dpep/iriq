package iriq

import (
	"regexp"
	"strconv"
	"strings"
	"sync"
)

// SegmentType is the discriminator returned by the SegmentClassifier.
type SegmentType string

const (
	TypeLiteral    SegmentType = "literal"
	TypeInteger  SegmentType = "integer"
	TypeFloat      SegmentType = "float"
	// TypeNumber is a corpus-only umbrella surfaced by Cluster.ParamType
	// when both :integer and :float observations exist at the same
	// position without either hitting a strong majority. The classifier
	// never returns TypeNumber for an individual value.
	TypeNumber    SegmentType = "number"
	TypeUUID       SegmentType = "uuid"
	TypeDate       SegmentType = "date"
	TypeTimestamp  SegmentType = "timestamp"
	TypeHash       SegmentType = "hash"
	TypeSlug       SegmentType = "slug"
	TypeIPv4       SegmentType = "ipv4"
	TypeIPv6       SegmentType = "ipv6"
	TypeURL        SegmentType = "url"
	TypeEmail      SegmentType = "email"
	TypeBoolean    SegmentType = "boolean"
	TypeVersion    SegmentType = "version"
	TypeLocale     SegmentType = "locale"
	TypeCurrency   SegmentType = "currency"
	TypePhone      SegmentType = "phone"
	TypeJWT        SegmentType = "jwt"
	TypeMIME       SegmentType = "mime"
	TypeFile       SegmentType = "file"
	TypeColor      SegmentType = "color"
	TypeCoordinate SegmentType = "coordinate"
	TypeCountry    SegmentType = "country"
	TypeBase64     SegmentType = "base64"
	TypeYear       SegmentType = "year"
	// TypeHTTPStatus is a corpus-only umbrella for positions whose values
	// cluster in the 100..599 HTTP status window. Same range-promotion
	// pattern as TypeYear — see Cluster.ParamType.
	TypeHTTPStatus SegmentType = "http_status"
	// TypeEnum is a corpus-only umbrella surfaced by Cluster.ParamType when
	// a position has a bounded set of repeated values across enough samples
	// (see Enum* thresholds in cluster.go).
	TypeEnum       SegmentType = "enum"
	// TypeString is the rung below TypeEnum: a param that varies across
	// free-form literal values but isn't a confident bounded set yet.
	// Corpus-only — never returned for a single value.
	TypeString     SegmentType = "string"
	TypeOpaqueID   SegmentType = "opaque_id"
)

var (
	// A float requires a decimal point and digits on both sides. Sign
	// optional. Bare integers fall through to integerRecognizer.
	floatRE   = regexp.MustCompile(`^-?\d+\.\d+$`)
	// ISO 8601 timestamp shapes (RFC 3339-ish). Date-only forms live on
	// dateRecognizer / integerRecognizer.
	isoTimeRE = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+\-]\d{2}:?\d{2})?$`)
	hashRE    = regexp.MustCompile(`^[0-9a-fA-F]{32,}$`)
	slugRE    = regexp.MustCompile(`^[a-z0-9]+(?:[-_][a-z0-9]+)+$`)
	// Unicode letter at the start followed by letters/marks/underscore.
	literalRE = regexp.MustCompile(`^\p{L}[\p{L}\p{M}_]*$`)
	opaqueRE  = regexp.MustCompile(`^[A-Za-z0-9_\-.~]{4,}$`)

	// Network / structured-value patterns. Validated past the regex by
	// helpers (octet bounds for IPv4, double-colon presence for IPv6).
	// ipv4RE itself is defined in registrable_domain.go — reused here.
	// IPv6: full 8-group OR contains "::". Doesn't match bare hex /
	// integers / single-colon strings, so :integer / :hash aren't
	// shadowed. Skipping IPv4-mapped variants for now.
	ipv6FullRE       = regexp.MustCompile(`^[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4}){7}$`)
	ipv6CompressedRE = regexp.MustCompile(`^[0-9a-fA-F:]{2,}$`)
	urlRE            = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9+.\-]*://\S+$`)
	// Scheme-less URL — `foo.com/path`, `sub.foo.com/`, etc. Requires a
	// dotted host with a TLD-like suffix (≥2 letters) followed by a slash
	// to disambiguate from filenames like `image.png` or version strings.
	schemelessURLRE  = regexp.MustCompile(`^[a-zA-Z0-9\-]+(?:\.[a-zA-Z0-9\-]+)*\.[a-zA-Z]{2,}/\S*$`)
	emailRE          = regexp.MustCompile(`^[A-Za-z0-9._%+\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)+$`)

	// Boolean literal — case-insensitive. `0`/`1` look like integers from
	// a single value alone; the corpus's :enum detection picks them up
	// when they appear as a bounded set on a param.
	booleanRE = regexp.MustCompile(`^(?i:true|false)$`)
	// SemVer-ish version with explicit `v` prefix.
	versionRE = regexp.MustCompile(`^v\d+(?:\.\d+)*(?:[-+][A-Za-z0-9.\-]+)?$`)
	// BCP 47-ish locale — language (2-3 lowercase) + separator + region or
	// script (2-4 alphanum). The bare 2-letter case is handled via the
	// inline ISO 639-1 allowlist below. classifyLocalePair also confirms
	// the language portion is in the allowlist so `by-locale` doesn't
	// wrongly promote.
	localeRE = regexp.MustCompile(`^([a-z]{2,3})[-_]([A-Za-z0-9]{2,4})$`)
	// Bare 2-letter slot; only :locale when it's in the language-code
	// allowlist. 3-letter slot is reserved for currencies.
	localeBareRE = regexp.MustCompile(`^[a-z]{2}$`)
	// Three-letter shape; validated against the inline ISO 4217 list in
	// classifyCurrency so we don't catch random 3-letter tokens.
	currencyRE = regexp.MustCompile(`^[A-Za-z]{3}$`)
	// E.164-ish phone — leading `+` then 7-20 chars of digits + separators.
	// The digit count is validated past the regex in classifyPhone (E.164
	// allows 7-15 digits).
	phoneRE = regexp.MustCompile(`^\+[ \-.()\d]{7,20}$`)
	// NANP phone without `+` — `555-666-7777`, `555.666.7777`, `(555) 666-7777`.
	// Leading area-code + exchange digit constrained to 2-9 so bare digit
	// blobs / dotted versions don't shadow other types.
	phoneNANPRE = regexp.MustCompile(`^\(?([2-9]\d{2})\)?[ \-.]?([2-9]\d{2})[ \-.]?(\d{4})$`)
	// File — `name.ext` shape where ext is in fileExtensionKind. The
	// stem can be a slug/opaque-id/literal; the meaningful signal is
	// the extension. See computeClassification → classifyFile.
	fileRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_\-.~]*\.([A-Za-z0-9]{1,8})$`)
	// Hex color — `#fff`, `#ffff`, `#ffffff`, `#ffffff80`. Other color
	// formats aren't recognized yet.
	colorHexRE = regexp.MustCompile(`^#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$`)
	// Coordinate pair — `lat,lng`, both signed decimals.
	coordinateRE = regexp.MustCompile(`^(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)$`)
	// 2-letter uppercase token, validated against countryCodes in
	// classifyCountry so random codes like `OK` don't promote.
	countryRE = regexp.MustCompile(`^[A-Z]{2}$`)
	// Standard base64 — ≥ 16 chars of base64 alphabet, with optional
	// `=` padding. Disambiguating chars (`+`/`/`/`=`) are checked
	// pre-regex so plain alphanumeric stays as :opaque_id.
	base64RE = regexp.MustCompile(`^[A-Za-z0-9+/]{16,}={0,2}$`)
	// JWT — three base64url-encoded parts separated by dots; header starts
	// with `ey` (`{` JSON prefix base64url-encoded).
	jwtRE = regexp.MustCompile(`^ey[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+$`)
	// MIME / media type — RFC 2046 top-level types plus a subtype. The
	// subtype side is permissive so `application/vnd.api+json` and
	// `image/svg+xml` both match.
	mimeRE = regexp.MustCompile(`^(?:text|image|video|audio|application|multipart|message|font|model)/[A-Za-z0-9!#$&^_+\-.]+$`)
)

// httpStatusMin / httpStatusMax mirror Ruby's HTTP_STATUS_RANGE.
const (
	httpStatusMin = 100
	httpStatusMax = 599
)

// countryCodes mirrors Ruby's COUNTRY_CODES — the ISO 3166-1 alpha-2
// allowlist used by classifyCountry to gate the promotion.
var countryCodes = map[string]struct{}{
	"AD": {}, "AE": {}, "AF": {}, "AG": {}, "AL": {}, "AM": {}, "AO": {}, "AR": {}, "AT": {}, "AU": {}, "AZ": {},
	"BA": {}, "BB": {}, "BD": {}, "BE": {}, "BG": {}, "BH": {}, "BJ": {}, "BM": {}, "BN": {}, "BO": {}, "BR": {}, "BS": {}, "BT": {}, "BW": {}, "BY": {}, "BZ": {},
	"CA": {}, "CD": {}, "CG": {}, "CH": {}, "CI": {}, "CL": {}, "CM": {}, "CN": {}, "CO": {}, "CR": {}, "CU": {}, "CY": {}, "CZ": {},
	"DE": {}, "DJ": {}, "DK": {}, "DM": {}, "DO": {}, "DZ": {},
	"EC": {}, "EE": {}, "EG": {}, "ER": {}, "ES": {}, "ET": {},
	"FI": {}, "FJ": {}, "FK": {}, "FM": {}, "FO": {}, "FR": {},
	"GA": {}, "GB": {}, "GE": {}, "GH": {}, "GI": {}, "GL": {}, "GM": {}, "GN": {}, "GR": {}, "GT": {}, "GU": {}, "GW": {}, "GY": {},
	"HK": {}, "HN": {}, "HR": {}, "HT": {}, "HU": {},
	"ID": {}, "IE": {}, "IL": {}, "IM": {}, "IN": {}, "IQ": {}, "IR": {}, "IS": {}, "IT": {},
	"JM": {}, "JO": {}, "JP": {},
	"KE": {}, "KG": {}, "KH": {}, "KM": {}, "KN": {}, "KP": {}, "KR": {}, "KW": {}, "KY": {}, "KZ": {},
	"LA": {}, "LB": {}, "LC": {}, "LI": {}, "LK": {}, "LR": {}, "LS": {}, "LT": {}, "LU": {}, "LV": {}, "LY": {},
	"MA": {}, "MC": {}, "MD": {}, "ME": {}, "MG": {}, "MK": {}, "ML": {}, "MM": {}, "MN": {}, "MO": {}, "MR": {}, "MT": {}, "MU": {}, "MV": {}, "MW": {}, "MX": {}, "MY": {}, "MZ": {},
	"NA": {}, "NE": {}, "NG": {}, "NI": {}, "NL": {}, "NO": {}, "NP": {}, "NR": {}, "NU": {}, "NZ": {},
	"OM": {},
	"PA": {}, "PE": {}, "PF": {}, "PG": {}, "PH": {}, "PK": {}, "PL": {}, "PR": {}, "PT": {}, "PW": {}, "PY": {},
	"QA": {},
	"RE": {}, "RO": {}, "RS": {}, "RU": {}, "RW": {},
	"SA": {}, "SB": {}, "SC": {}, "SD": {}, "SE": {}, "SG": {}, "SI": {}, "SK": {}, "SL": {}, "SM": {}, "SN": {}, "SO": {}, "SR": {}, "SS": {}, "ST": {}, "SV": {}, "SY": {}, "SZ": {},
	"TD": {}, "TG": {}, "TH": {}, "TJ": {}, "TM": {}, "TN": {}, "TO": {}, "TR": {}, "TT": {}, "TV": {}, "TW": {}, "TZ": {},
	"UA": {}, "UG": {}, "US": {}, "UY": {}, "UZ": {},
	"VA": {}, "VC": {}, "VE": {}, "VG": {}, "VI": {}, "VN": {}, "VU": {},
	"WS": {},
	"YE": {},
	"ZA": {}, "ZM": {}, "ZW": {},
}

// ColorKind mirrors Ruby's color_kind helper — returns "hex" for
// hex-shaped color values, "" otherwise. Placeholder for future named /
// rgb / hsl support.
func ColorKind(value string) string {
	if colorHexRE.MatchString(value) {
		return "hex"
	}
	return ""
}

// FileKind is the per-extension category for :file values — surfaced
// via FileKind(value) for verbose displays.
type FileKind string

const (
	FileKindImage    FileKind = "image"
	FileKindDocument FileKind = "document"
	FileKindData     FileKind = "data"
	FileKindText     FileKind = "text"
	FileKindWeb      FileKind = "web"
	FileKindAudio    FileKind = "audio"
	FileKindVideo    FileKind = "video"
	FileKindArchive  FileKind = "archive"
	FileKindCode     FileKind = "code"
)

// fileExtensionKind mirrors Ruby's FILE_EXTENSION_KIND — a curated
// allowlist of common extensions per category. Keep this list narrow:
// random 1-8 char endings can shadow semantic types if widened.
var fileExtensionKind = map[string]FileKind{
	"png": FileKindImage, "jpg": FileKindImage, "jpeg": FileKindImage,
	"gif": FileKindImage, "webp": FileKindImage, "svg": FileKindImage,
	"bmp": FileKindImage, "tiff": FileKindImage, "tif": FileKindImage,
	"ico": FileKindImage, "avif": FileKindImage, "heic": FileKindImage,
	"heif": FileKindImage,
	"pdf":  FileKindDocument, "doc": FileKindDocument, "docx": FileKindDocument,
	"xls":  FileKindDocument, "xlsx": FileKindDocument, "ppt": FileKindDocument,
	"pptx": FileKindDocument, "odt": FileKindDocument, "ods": FileKindDocument,
	"odp":  FileKindDocument, "rtf": FileKindDocument, "epub": FileKindDocument,
	"csv": FileKindData, "tsv": FileKindData, "json": FileKindData,
	"xml":     FileKindData, "yaml": FileKindData, "yml": FileKindData,
	"parquet": FileKindData, "sqlite": FileKindData, "db": FileKindData,
	"ndjson":  FileKindData, "jsonl": FileKindData,
	"txt": FileKindText, "md": FileKindText, "log": FileKindText,
	"markdown": FileKindText, "rst": FileKindText,
	"html": FileKindWeb, "htm": FileKindWeb, "css": FileKindWeb,
	"js":  FileKindWeb, "mjs": FileKindWeb, "cjs": FileKindWeb,
	"ts":  FileKindWeb, "jsx": FileKindWeb, "tsx": FileKindWeb,
	"mp3": FileKindAudio, "wav": FileKindAudio, "ogg": FileKindAudio,
	"flac": FileKindAudio, "aac": FileKindAudio, "m4a": FileKindAudio,
	"opus": FileKindAudio,
	"mp4": FileKindVideo, "mov": FileKindVideo, "avi": FileKindVideo,
	"mkv": FileKindVideo, "webm": FileKindVideo, "flv": FileKindVideo,
	"wmv": FileKindVideo, "m4v": FileKindVideo,
	"zip": FileKindArchive, "tar": FileKindArchive, "gz": FileKindArchive,
	"bz2": FileKindArchive, "7z": FileKindArchive, "rar": FileKindArchive,
	"xz":  FileKindArchive, "tgz": FileKindArchive,
	"rb": FileKindCode, "py": FileKindCode, "go": FileKindCode,
	"java": FileKindCode, "c": FileKindCode, "cc": FileKindCode,
	"cpp":  FileKindCode, "h": FileKindCode, "hpp": FileKindCode,
	"sh":   FileKindCode, "swift": FileKindCode, "kt": FileKindCode,
	"rs":   FileKindCode,
}

// FileKindOf returns the kind (image/document/data/etc.) for a
// file-shaped value, or "" if the value isn't a recognized file.
// Used by verbose displays to subdivide TypeFile without polluting
// the top-level type taxonomy.
func FileKindOf(value string) FileKind {
	m := fileExtRE.FindStringSubmatch(value)
	if m == nil {
		return ""
	}
	return fileExtensionKind[strings.ToLower(m[1])]
}

// fileExtRE extracts the trailing extension from a file-shaped string.
var fileExtRE = regexp.MustCompile(`\.([A-Za-z0-9]{1,8})$`)

// paramNameHints mirrors Ruby's PARAM_NAME_HINTS. Param names that map
// to a semantic type lift generic-classified values (literal / opaque_id
// / slug) — `?phone=unknown` becomes TypePhone.
var paramNameHints = map[string]SegmentType{
	"phone":        TypePhone,
	"tel":          TypePhone,
	"telephone":    TypePhone,
	"mobile":       TypePhone,
	"cell":         TypePhone,
	"email":        TypeEmail,
	"e_mail":       TypeEmail,
	"mail":         TypeEmail,
	"locale":       TypeLocale,
	"lang":         TypeLocale,
	"language":     TypeLocale,
	"currency":     TypeCurrency,
	"cur":          TypeCurrency,
	"curr":         TypeCurrency,
	"url":          TypeURL,
	"uri":          TypeURL,
	"redirect":     TypeURL,
	"redirect_url": TypeURL,
	"return_to":    TypeURL,
	"return_url":   TypeURL,
	"callback":     TypeURL,
	"callback_url": TypeURL,
	"next_url":     TypeURL,
	"jwt":          TypeJWT,
	"bearer":       TypeJWT,
	"auth_token":   TypeJWT,
	"mime":         TypeMIME,
	"content_type": TypeMIME,
	"media_type":   TypeMIME,
	"color":        TypeColor,
	"colour":       TypeColor,
	"bg":           TypeColor,
	"background":   TypeColor,
	"fg":           TypeColor,
	"foreground":   TypeColor,
	"coords":       TypeCoordinate,
	"coordinates":  TypeCoordinate,
	"geo":          TypeCoordinate,
	"location":     TypeCoordinate,
	"position":     TypeCoordinate,
	"latlng":       TypeCoordinate,
	"latlon":       TypeCoordinate,
	"country":      TypeCountry,
	"country_code": TypeCountry,
	"nation":       TypeCountry,
}

// paramHintOverridable lists the generic types eligible for param-name
// override. Anything more specific (TypeInteger, TypeUUID, etc.) carries
// useful info already.
var paramHintOverridable = map[SegmentType]struct{}{
	TypeLiteral:  {},
	TypeOpaqueID: {},
	TypeSlug:     {},
}

// ParamNameHint returns a hinted type for a param name when the resolved
// value type is generic. Returns "" when no hint applies. Both
// Cluster.ParamType (corpus path) and Normalizer.shapeQuery (one-shot)
// consult this so corpus + one-shot agree on the override.
func ParamNameHint(name string, current SegmentType) SegmentType {
	if name == "" {
		return ""
	}
	if _, ok := paramHintOverridable[current]; !ok {
		return ""
	}
	return paramNameHints[strings.ToLower(name)]
}

// localeLanguageCodes is the inline ISO 639-1 (subset) — codes commonly
// used in real `?lang=` traffic. Tokens not in the list (`if`, `to`)
// stay as :literal.
var localeLanguageCodes = map[string]struct{}{
	"ar": {}, "bg": {}, "bn": {}, "ca": {}, "cs": {}, "da": {}, "de": {}, "el": {},
	"en": {}, "es": {}, "et": {}, "fa": {}, "fi": {}, "fr": {}, "gu": {}, "he": {},
	"hi": {}, "hr": {}, "hu": {}, "id": {}, "it": {}, "ja": {}, "ka": {}, "kk": {},
	"km": {}, "kn": {}, "ko": {}, "lt": {}, "lv": {}, "mk": {}, "ml": {}, "mr": {},
	"ms": {}, "my": {}, "nb": {}, "nl": {}, "no": {}, "pa": {}, "pl": {}, "pt": {},
	"ro": {}, "ru": {}, "sk": {}, "sl": {}, "sr": {}, "sv": {}, "sw": {}, "ta": {},
	"te": {}, "th": {}, "tl": {}, "tr": {}, "uk": {}, "ur": {}, "vi": {}, "zh": {},
}

// currencyCodes is the inline ISO 4217 allowlist — ~35 entries covering
// the most-used codes in real traffic. Full PSL-style coverage would add
// ~180 entries; this list is the 80/20 hit.
var currencyCodes = map[string]struct{}{
	"USD": {}, "EUR": {}, "GBP": {}, "JPY": {}, "CNY": {}, "CHF": {}, "CAD": {},
	"AUD": {}, "NZD": {}, "HKD": {}, "SGD": {}, "INR": {}, "KRW": {}, "MXN": {},
	"BRL": {}, "ZAR": {}, "SEK": {}, "NOK": {}, "DKK": {}, "PLN": {}, "CZK": {},
	"HUF": {}, "RUB": {}, "TRY": {}, "ILS": {}, "AED": {}, "SAR": {}, "THB": {},
	"IDR": {}, "PHP": {}, "VND": {}, "TWD": {}, "MYR": {}, "NGN": {}, "EGP": {},
}

// yearMin / yearMax mirror the Ruby YEAR_RANGE.
const (
	yearMin = 1900
	yearMax = 2100
)

const (
	classifierCacheMax = 10_000
)

// SegmentClassifier is a heuristic classifier for individual path segments
// and query values. Returns the first matching type — order matters.
//
// The recognizer ensemble consulted at classify time is held on the
// instance (recognizers field). Defaults to the built-in three (uuid,
// date, integer); Corpus.ActivateProposal appends SynthesizedRecognizer
// instances at runtime so a corpus picks up its learned patterns
// without classifier surgery.
type SegmentClassifier struct {
	mu          sync.Mutex
	cache       map[string]SegmentType
	recognizers []Recognizer
}

func NewSegmentClassifier() *SegmentClassifier {
	return &SegmentClassifier{
		cache:       map[string]SegmentType{},
		recognizers: []Recognizer{UUIDRecognizer, DateRecognizer, IntegerRecognizer},
	}
}

// RegisterRecognizer appends a Recognizer to the ensemble. Called by
// Corpus.ActivateProposal to promote a RecognizerProposal into a live
// Recognizer. Busts the classify cache so subsequent Classify() calls
// see the new Recognizer.
func (c *SegmentClassifier) RegisterRecognizer(r Recognizer) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.recognizers = append(c.recognizers, r)
	c.cache = map[string]SegmentType{}
}

// Recognizers returns a snapshot of the live ensemble. Useful for tests
// and tooling that want to inspect which Recognizers a corpus consults.
func (c *SegmentClassifier) Recognizers() []Recognizer {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]Recognizer, len(c.recognizers))
	copy(out, c.recognizers)
	return out
}

// DefaultClassifier mirrors Ruby's SegmentClassifier::DEFAULT — a shared,
// reusable instance for callers that don't want to manage a cache themselves.
var DefaultClassifier = NewSegmentClassifier()

func (c *SegmentClassifier) Classify(segment string) SegmentType {
	if segment == "" {
		return TypeLiteral
	}
	c.mu.Lock()
	if v, ok := c.cache[segment]; ok {
		c.mu.Unlock()
		return v
	}
	if len(c.cache) >= classifierCacheMax {
		c.cache = map[string]SegmentType{}
	}
	c.mu.Unlock()

	c.mu.Lock()
	rs := c.recognizers
	c.mu.Unlock()
	t := computeClassification(segment, rs)

	c.mu.Lock()
	c.cache[segment] = t
	c.mu.Unlock()
	return t
}

// Variable reports whether a segment type is treated as variable for
// shape/explain rendering — anything other than :literal.
func (c *SegmentClassifier) Variable(t SegmentType) bool {
	return t != TypeLiteral
}

func computeClassification(segment string, recognizers []Recognizer) SegmentType {
	// Cheap composition checks short-circuit regex matches that can't
	// possibly fire. Each `xRE.MatchString` below is preceded by an
	// `IndexByte` / `size` guard so a literal like "users" walks past
	// 20-odd regex tests in O(len) instead of O(len * n_regexes).
	size := len(segment)
	first := byte(0)
	if size > 0 {
		first = segment[0]
	}
	digit0 := first >= '0' && first <= '9'
	hasDash := strings.IndexByte(segment, '-') >= 0
	hasDot := strings.IndexByte(segment, '.') >= 0
	hasColon := strings.IndexByte(segment, ':') >= 0
	hasSlash := strings.IndexByte(segment, '/') >= 0
	hasAt := strings.IndexByte(segment, '@') >= 0
	hasUnder := strings.IndexByte(segment, '_') >= 0
	hasSep := hasDash || hasUnder
	hasComma := strings.IndexByte(segment, ',') >= 0
	hasEq := strings.IndexByte(segment, '=') >= 0
	hasPlus := strings.IndexByte(segment, '+') >= 0

	// Scored ensemble over the extracted Recognizers. Today only three
	// participate (uuid, date, integer) and they're mutually-exclusive on
	// shape, so the ensemble's max-specificity tie-break never actually
	// fires — but the seam is in place for follow-up commits that carve
	// more Recognizers out and let scoring decide.
	if v, ok := Ensemble(segment, recognizers...); ok {
		return v.Type
	}

	switch {
	case size > 4 && segment[0] == 'e' && segment[1] == 'y' && strings.Count(segment, ".") == 2 && jwtRE.MatchString(segment):
		return TypeJWT
	case first == '#' && colorHexRE.MatchString(segment):
		return TypeColor
	// Network / structured types take precedence over the generic opaqueRE
	// catch-all (which would otherwise grab IPv4) and the literal fallback
	// (which today swallows email + URL + IPv6).
	case hasColon && strings.Contains(segment, "://") && urlRE.MatchString(segment):
		return TypeURL
	case hasAt && emailRE.MatchString(segment):
		return TypeEmail
	case hasSlash && mimeRE.MatchString(segment):
		return TypeMIME
	case hasDot && hasSlash && schemelessURLRE.MatchString(segment):
		return TypeURL
	case digit0 && hasDot && ipv4RE.MatchString(segment):
		return classifyIPv4(segment)
	case hasColon && ipv6FullRE.MatchString(segment):
		return TypeIPv6
	case hasColon && strings.Contains(segment, "::") && ipv6CompressedRE.MatchString(segment):
		return TypeIPv6
	case hasComma && coordinateRE.MatchString(segment):
		return classifyCoordinate(segment)
	case size >= 32 && hashRE.MatchString(segment):
		return TypeHash
	case first == 'v' && versionRE.MatchString(segment):
		return TypeVersion
	case (size >= 4 && size <= 5) && booleanRE.MatchString(segment):
		return TypeBoolean
	case hasSep && localeRE.MatchString(segment):
		return classifyLocalePair(segment)
	case size == 2 && localeBareRE.MatchString(segment):
		return classifyLocaleBare(segment)
	case hasColon && isoTimeRE.MatchString(segment):
		return TypeTimestamp
	case first == '+' && phoneRE.MatchString(segment):
		return classifyPhone(segment)
	case (hasDash || hasDot || segment[0] == '(') && phoneNANPRE.MatchString(segment):
		return TypePhone
	case hasDot && floatRE.MatchString(segment):
		return TypeFloat
	case size == 3 && currencyRE.MatchString(segment):
		return classifyCurrency(segment)
	case size == 2 && countryRE.MatchString(segment):
		return classifyCountry(segment)
	case size >= 16 && (hasEq || hasPlus || hasSlash) && base64RE.MatchString(segment):
		return TypeBase64
	case hasDot && fileRE.MatchString(segment):
		return classifyFile(segment)
	case hasSep && slugRE.MatchString(segment):
		return TypeSlug
	case literalRE.MatchString(segment):
		return TypeLiteral
	case opaqueRE.MatchString(segment):
		return TypeOpaqueID
	}
	return TypeLiteral
}

// classifyCoordinate validates a `lat,lng` pair — both components must
// land in plausible lat/lng bounds. Accepts either ordering since we
// can't tell which is which from one value.
func classifyCoordinate(segment string) SegmentType {
	m := coordinateRE.FindStringSubmatch(segment)
	if m == nil {
		return TypeOpaqueID
	}
	a, errA := strconv.ParseFloat(m[1], 64)
	b, errB := strconv.ParseFloat(m[2], 64)
	if errA != nil || errB != nil {
		return TypeOpaqueID
	}
	if (a >= -90 && a <= 90 && b >= -180 && b <= 180) ||
		(a >= -180 && a <= 180 && b >= -90 && b <= 90) {
		return TypeCoordinate
	}
	return TypeOpaqueID
}

// classifyCountry promotes a 2-letter uppercase token to TypeCountry
// only when it's in the ISO 3166-1 alpha-2 allowlist.
func classifyCountry(segment string) SegmentType {
	if _, ok := countryCodes[segment]; ok {
		return TypeCountry
	}
	return TypeLiteral
}

// classifyFile promotes a `name.ext` shape to TypeFile only when ext is
// in the kind allowlist. Otherwise falls through to slug/opaque so
// version-shaped values like `1.2.3` aren't pulled in.
func classifyFile(segment string) SegmentType {
	m := fileRE.FindStringSubmatch(segment)
	if m == nil {
		return TypeOpaqueID
	}
	ext := strings.ToLower(m[1])
	if _, ok := fileExtensionKind[ext]; ok {
		return TypeFile
	}
	if slugRE.MatchString(segment) {
		return TypeSlug
	}
	return TypeOpaqueID
}

// classifyPhone counts digits (ignoring separators) and confirms the count
// falls in the E.164 7-15 range. Falls back to TypeOpaqueID otherwise.
func classifyPhone(segment string) SegmentType {
	digits := 0
	for _, r := range segment {
		if r >= '0' && r <= '9' {
			digits++
		}
	}
	if digits >= 7 && digits <= 15 {
		return TypePhone
	}
	return TypeOpaqueID
}

// classifyCurrency upgrades a 3-letter token to TypeCurrency only when
// it's in the ISO 4217 allowlist. Otherwise falls through to the literal
// rules so random 3-letter words like FAQ don't get promoted.
func classifyCurrency(segment string) SegmentType {
	if _, ok := currencyCodes[strings.ToUpper(segment)]; ok {
		return TypeCurrency
	}
	if literalRE.MatchString(segment) {
		return TypeLiteral
	}
	return TypeOpaqueID
}

// classifyLocaleBare promotes a bare 2-letter token to TypeLocale when
// it's a known ISO 639-1 code. Otherwise it's a regular literal.
func classifyLocaleBare(segment string) SegmentType {
	if _, ok := localeLanguageCodes[segment]; ok {
		return TypeLocale
	}
	return TypeLiteral
}

// classifyLocalePair handles the dashed/underscored locale form. Only
// promotes to TypeLocale when the language portion is in the ISO 639-1
// allowlist — guards against `by-locale` and similar.
func classifyLocalePair(segment string) SegmentType {
	m := localeRE.FindStringSubmatch(segment)
	if m == nil {
		return TypeLiteral
	}
	if _, ok := localeLanguageCodes[m[1]]; ok {
		return TypeLocale
	}
	if slugRE.MatchString(segment) {
		return TypeSlug
	}
	return TypeLiteral
}

// classifyIPv4 verifies that each dotted-quad octet ≤ 255. Falls back to
// TypeOpaqueID so garbage like "999.999.999.999" doesn't get promoted.
func classifyIPv4(segment string) SegmentType {
	for _, oct := range strings.Split(segment, ".") {
		n, err := strconv.Atoi(oct)
		if err != nil || n < 0 || n > 255 {
			return TypeOpaqueID
		}
	}
	return TypeIPv4
}

// DisplayType returns the type name used in `--normalize` placeholders.
// Collapses TypeIPv4 and TypeIPv6 to "ip" — callers that want the
// specific family read it off the classifier directly or via cluster
// stats.
func DisplayType(t SegmentType) string {
	switch t {
	case TypeIPv4, TypeIPv6:
		return "ip"
	}
	return string(t)
}

// CanonicalCurrency upcases a known ISO 4217 currency code. Returns "" if
// the value isn't a known code. Used by --normalize so /pricing/usd and
// /pricing/USD both render as /pricing/USD.
func CanonicalCurrency(value string) string {
	if value == "" {
		return ""
	}
	up := strings.ToUpper(value)
	if _, ok := currencyCodes[up]; ok {
		return up
	}
	return ""
}

// CanonicalDate normalizes a recognized date string to ISO 8601 (YYYY-MM-DD).
// Returns "" if the value isn't one of the accepted date forms or the
// year/month/day fall outside plausible bounds.
func CanonicalDate(value string) string {
	if canon := canonicalDateFromForms(value); canon != "" {
		return canon
	}
	// Compact YYYYMMDD lives on integerRecognizer for classification, but
	// the canonical form is part of the same date family.
	if compactDatePattern.MatchString(value) {
		if plausibleDate(value[0:4], value[4:6], value[6:8]) {
			return value[0:4] + "-" + value[4:6] + "-" + value[6:8]
		}
	}
	return ""
}

func pad2(s string) string {
	if len(s) == 1 {
		return "0" + s
	}
	return s
}
