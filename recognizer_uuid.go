package iriq

import (
	"regexp"
	"strings"
)

// uuidRecognizer is the RFC 4122 UUID Recognizer. Shape-only — does not
// validate version/variant bits.
type uuidRecognizer struct{}

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func (uuidRecognizer) Try(segment string) (Verdict, bool) {
	if len(segment) != 36 || strings.IndexByte(segment, '-') < 0 || !uuidPattern.MatchString(segment) {
		return Verdict{}, false
	}
	return Verdict{Type: TypeUUID, Confidence: 1.0, Specificity: SpecificitySemantic}, true
}

// UUIDRecognizer is the shared singleton — Recognizers are stateless, so
// callers can reuse this instead of allocating per call.
var UUIDRecognizer Recognizer = uuidRecognizer{}
