package iriq

import (
	"regexp"
	"strconv"
	"strings"
)

// dateRecognizer recognizes ISO 8601 (YYYY-MM-DD), slash form
// (YYYY/MM/DD), and US-style (M/D/YYYY) date shapes. Compact YYYYMMDD
// lives on the Integer recognizer — the digits-only shape sees it first.
//
// Conservative: DD/MM/YYYY is intentionally NOT recognized — from a bare
// segment we can't tell it apart from MM/DD/YYYY.
type dateRecognizer struct{}

var (
	dateISOPattern   = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
	dateSlashPattern = regexp.MustCompile(`^\d{4}/\d{2}/\d{2}$`)
	dateUSPattern    = regexp.MustCompile(`^(\d{1,2})/(\d{1,2})/(\d{4})$`)
)

func (dateRecognizer) Try(segment string) (Verdict, bool) {
	hasDash := strings.IndexByte(segment, '-') >= 0
	hasSlash := strings.IndexByte(segment, '/') >= 0
	if !hasDash && !hasSlash {
		return Verdict{}, false
	}
	if !dateISOPattern.MatchString(segment) &&
		!dateSlashPattern.MatchString(segment) &&
		!dateUSPattern.MatchString(segment) {
		return Verdict{}, false
	}
	return Verdict{Type: TypeDate, Confidence: 1.0, Specificity: SpecificityStructured}, true
}

// DateRecognizer is the shared singleton.
var DateRecognizer Recognizer = dateRecognizer{}

// canonicalDateFromForms normalizes one of the date forms this Recognizer
// claims to ISO 8601 (YYYY-MM-DD). Returns "" if not recognized or if
// y/m/d fall outside the plausible window. Compact YYYYMMDD is handled
// at the SegmentClassifier level since it's part of the Integer family.
func canonicalDateFromForms(value string) string {
	switch {
	case dateISOPattern.MatchString(value):
		if plausibleDate(value[0:4], value[5:7], value[8:10]) {
			return value
		}
	case dateSlashPattern.MatchString(value):
		if plausibleDate(value[0:4], value[5:7], value[8:10]) {
			return value[0:4] + "-" + value[5:7] + "-" + value[8:10]
		}
	case dateUSPattern.MatchString(value):
		m := dateUSPattern.FindStringSubmatch(value)
		mon, day, year := pad2(m[1]), pad2(m[2]), m[3]
		if plausibleDate(year, mon, day) {
			return year + "-" + mon + "-" + day
		}
	}
	return ""
}

// plausibleDate is a fast bounds check shared by the Date / Integer
// recognizers and CanonicalDate. Day-of-month validity (Feb 30, Apr 31)
// is intentionally not checked — out of scope for a heuristic.
func plausibleDate(y, m, d string) bool {
	yi, _ := strconv.Atoi(y)
	mi, _ := strconv.Atoi(m)
	di, _ := strconv.Atoi(d)
	return yi >= 1900 && yi <= 2100 && mi >= 1 && mi <= 12 && di >= 1 && di <= 31
}
