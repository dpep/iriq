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
	TypeIntegerID  SegmentType = "integer_id"
	TypeFloat      SegmentType = "float"
	// TypeNumeric is a corpus-only umbrella surfaced by Cluster.ParamType
	// when both :integer_id and :float observations exist at the same
	// position without either hitting a strong majority. The classifier
	// never returns TypeNumeric for an individual value.
	TypeNumeric    SegmentType = "numeric"
	TypeUUID       SegmentType = "uuid"
	TypeDate       SegmentType = "date"
	TypeTimestamp  SegmentType = "timestamp"
	TypeHash       SegmentType = "hash"
	TypeSlug       SegmentType = "slug"
	TypeIPv4       SegmentType = "ipv4"
	TypeIPv6       SegmentType = "ipv6"
	TypeURL        SegmentType = "url"
	TypeEmail      SegmentType = "email"
	TypeOpaqueID   SegmentType = "opaque_id"
)

var (
	uuidRE    = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
	integerRE = regexp.MustCompile(`^\d+$`)
	// A float requires a decimal point and digits on both sides. Sign
	// optional. Bare integers fall through to integerRE.
	floatRE   = regexp.MustCompile(`^-?\d+\.\d+$`)
	// Date formats we'll canonicalize. Deliberately conservative — only the
	// unambiguous forms where the year position is fixed. DD/MM/YYYY isn't
	// recognized (can't be told apart from MM/DD/YYYY from a segment alone).
	// Slash forms only show up in query-param values — URL path separators
	// rule them out for path segments.
	dateRE        = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
	dateSlashRE   = regexp.MustCompile(`^\d{4}/\d{2}/\d{2}$`)
	dateUSRE      = regexp.MustCompile(`^(\d{1,2})/(\d{1,2})/(\d{4})$`)
	dateCompactRE = regexp.MustCompile(`^\d{8}$`)
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
	// integers / single-colon strings, so :integer_id / :hash aren't
	// shadowed. Skipping IPv4-mapped variants for now.
	ipv6FullRE       = regexp.MustCompile(`^[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4}){7}$`)
	ipv6CompressedRE = regexp.MustCompile(`^[0-9a-fA-F:]{2,}$`)
	urlRE            = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9+.\-]*://\S+$`)
	emailRE          = regexp.MustCompile(`^[A-Za-z0-9._%+\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)+$`)
)

const (
	tsSecondsMin int64 = 1_000_000_000
	tsSecondsMax int64 = 9_999_999_999
	tsMillisMin  int64 = 1_000_000_000_000
	tsMillisMax  int64 = 9_999_999_999_999

	classifierCacheMax = 10_000
)

// SegmentClassifier is a heuristic classifier for individual path segments and
// query values. Returns the first matching type — order matters.
type SegmentClassifier struct {
	mu    sync.Mutex
	cache map[string]SegmentType
}

func NewSegmentClassifier() *SegmentClassifier {
	return &SegmentClassifier{cache: map[string]SegmentType{}}
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

	t := computeClassification(segment)

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

func computeClassification(segment string) SegmentType {
	switch {
	case uuidRE.MatchString(segment):
		return TypeUUID
	// Network / structured types take precedence over the generic opaqueRE
	// catch-all (which would otherwise grab IPv4) and the literal fallback
	// (which today swallows email + URL + IPv6).
	case urlRE.MatchString(segment):
		return TypeURL
	case emailRE.MatchString(segment):
		return TypeEmail
	case ipv4RE.MatchString(segment):
		return classifyIPv4(segment)
	case ipv6FullRE.MatchString(segment):
		return TypeIPv6
	case strings.Contains(segment, "::") && ipv6CompressedRE.MatchString(segment):
		return TypeIPv6
	case dateRE.MatchString(segment), dateSlashRE.MatchString(segment), dateUSRE.MatchString(segment):
		return TypeDate
	case isoTimeRE.MatchString(segment):
		return TypeTimestamp
	case integerRE.MatchString(segment):
		return classifyInteger(segment)
	case floatRE.MatchString(segment):
		return TypeFloat
	case hashRE.MatchString(segment):
		return TypeHash
	case slugRE.MatchString(segment):
		return TypeSlug
	case literalRE.MatchString(segment):
		return TypeLiteral
	case opaqueRE.MatchString(segment):
		return TypeOpaqueID
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

func classifyInteger(segment string) SegmentType {
	n, err := strconv.ParseInt(segment, 10, 64)
	if err != nil {
		// Out of int64 range: definitely larger than the timestamp window,
		// keep as plain integer_id.
		return TypeIntegerID
	}
	if n >= tsMillisMin && n <= tsMillisMax {
		return TypeTimestamp
	}
	if n >= tsSecondsMin && n <= tsSecondsMax {
		return TypeTimestamp
	}

	// Plausible YYYYMMDD: be strict on year + month + day so 8-digit IDs
	// don't get mis-classified as dates.
	if dateCompactRE.MatchString(segment) {
		y, _ := strconv.Atoi(segment[0:4])
		m, _ := strconv.Atoi(segment[4:6])
		d, _ := strconv.Atoi(segment[6:8])
		if y >= 1900 && y <= 2100 && m >= 1 && m <= 12 && d >= 1 && d <= 31 {
			return TypeDate
		}
	}

	return TypeIntegerID
}

// CanonicalDate normalizes a recognized date string to ISO 8601 (YYYY-MM-DD).
// Returns "" if the value isn't one of the accepted date forms or the
// year/month/day fall outside plausible bounds.
func CanonicalDate(value string) string {
	switch {
	case dateRE.MatchString(value):
		if plausibleDate(value[0:4], value[5:7], value[8:10]) {
			return value
		}
	case dateSlashRE.MatchString(value):
		if plausibleDate(value[0:4], value[5:7], value[8:10]) {
			return value[0:4] + "-" + value[5:7] + "-" + value[8:10]
		}
	case dateUSRE.MatchString(value):
		// MM/DD/YYYY with 1-2 digit month and day — zero-pad both for output.
		m := dateUSRE.FindStringSubmatch(value)
		mon, day, year := pad2(m[1]), pad2(m[2]), m[3]
		if plausibleDate(year, mon, day) {
			return year + "-" + mon + "-" + day
		}
	case dateCompactRE.MatchString(value):
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

// plausibleDate is a fast bounds check on year/month/day. Doesn't validate
// day-of-month (Feb 30, Apr 31) — more nuance than this heuristic needs.
func plausibleDate(y, m, d string) bool {
	yi, _ := strconv.Atoi(y)
	mi, _ := strconv.Atoi(m)
	di, _ := strconv.Atoi(d)
	return yi >= 1900 && yi <= 2100 && mi >= 1 && mi <= 12 && di >= 1 && di <= 31
}
