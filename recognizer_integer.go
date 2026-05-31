package iriq

import (
	"regexp"
	"strconv"
)

// integerRecognizer recognizes base-10 integers. Also surfaces TypeTimestamp
// for plausible UNIX seconds / millis ranges and TypeDate for plausible
// compact YYYYMMDD — these share the digits-only lexical shape, and we
// want the most specific type.
type integerRecognizer struct{}

var (
	integerPattern     = regexp.MustCompile(`^\d+$`)
	compactDatePattern = regexp.MustCompile(`^\d{8}$`)
)

const (
	tsSecondsRangeMin int64 = 1_000_000_000
	tsSecondsRangeMax int64 = 9_999_999_999
	tsMillisRangeMin  int64 = 1_000_000_000_000
	tsMillisRangeMax  int64 = 9_999_999_999_999
)

func (integerRecognizer) Try(segment string) (Verdict, bool) {
	if segment == "" {
		return Verdict{}, false
	}
	c := segment[0]
	if c < '0' || c > '9' {
		return Verdict{}, false
	}
	if !integerPattern.MatchString(segment) {
		return Verdict{}, false
	}

	if n, err := strconv.ParseInt(segment, 10, 64); err == nil {
		if n >= tsMillisRangeMin && n <= tsMillisRangeMax {
			return Verdict{Type: TypeTimestamp, Confidence: 1.0}, true
		}
		if n >= tsSecondsRangeMin && n <= tsSecondsRangeMax {
			return Verdict{Type: TypeTimestamp, Confidence: 1.0}, true
		}
	}

	if compactDatePattern.MatchString(segment) {
		y, _ := strconv.Atoi(segment[0:4])
		m, _ := strconv.Atoi(segment[4:6])
		d, _ := strconv.Atoi(segment[6:8])
		if y >= 1900 && y <= 2100 && m >= 1 && m <= 12 && d >= 1 && d <= 31 {
			return Verdict{Type: TypeDate, Confidence: 1.0}, true
		}
	}

	return Verdict{Type: TypeInteger, Confidence: 1.0}, true
}

// IntegerRecognizer is the shared singleton.
var IntegerRecognizer Recognizer = integerRecognizer{}
