package iriq

import (
	"regexp"
	"strconv"
	"sync"
)

// SegmentType is the discriminator returned by the SegmentClassifier.
type SegmentType string

const (
	TypeLiteral    SegmentType = "literal"
	TypeIntegerID  SegmentType = "integer_id"
	TypeUUID       SegmentType = "uuid"
	TypeDate       SegmentType = "date"
	TypeTimestamp  SegmentType = "timestamp"
	TypeHash       SegmentType = "hash"
	TypeSlug       SegmentType = "slug"
	TypeOpaqueID   SegmentType = "opaque_id"
)

var (
	uuidRE    = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
	integerRE = regexp.MustCompile(`^\d+$`)
	dateRE    = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
	isoTimeRE = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+\-]\d{2}:?\d{2})?$`)
	hashRE    = regexp.MustCompile(`^[0-9a-fA-F]{32,}$`)
	slugRE    = regexp.MustCompile(`^[a-z0-9]+(?:[-_][a-z0-9]+)+$`)
	// Unicode letter at the start followed by letters/marks/underscore.
	literalRE = regexp.MustCompile(`^\p{L}[\p{L}\p{M}_]*$`)
	opaqueRE  = regexp.MustCompile(`^[A-Za-z0-9_\-.~]{4,}$`)
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
	case dateRE.MatchString(segment):
		return TypeDate
	case isoTimeRE.MatchString(segment):
		return TypeTimestamp
	case integerRE.MatchString(segment):
		return classifyInteger(segment)
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
	return TypeIntegerID
}
