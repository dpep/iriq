package iriq

import (
	"regexp"
	"strings"
	"sync"
	"unicode"
)

// InflectorAdapter is the swappable singularization backend. Set via
// SetInflectorAdapter or revert with ResetInflectorAdapter.
type InflectorAdapter interface {
	Singularize(word string) string
}

const inflectorCacheMax = 10_000

var (
	inflectorMu      sync.Mutex
	inflectorAdapter InflectorAdapter = BuiltinInflector{}
	inflectorCache                    = map[string]string{}
)

// Singularize returns the singular form of a word using the active adapter.
// Bounded cache mirrors the Ruby implementation.
func Singularize(word string) string {
	inflectorMu.Lock()
	if v, ok := inflectorCache[word]; ok {
		inflectorMu.Unlock()
		return v
	}
	if len(inflectorCache) >= inflectorCacheMax {
		inflectorCache = map[string]string{}
	}
	adapter := inflectorAdapter
	inflectorMu.Unlock()

	out := adapter.Singularize(word)

	inflectorMu.Lock()
	inflectorCache[word] = out
	inflectorMu.Unlock()
	return out
}

// SetInflectorAdapter swaps the singularization adapter and clears the cache
// (different adapters may produce different output for the same input).
func SetInflectorAdapter(a InflectorAdapter) {
	inflectorMu.Lock()
	inflectorAdapter = a
	inflectorCache = map[string]string{}
	inflectorMu.Unlock()
}

// ResetInflectorAdapter restores the built-in adapter.
func ResetInflectorAdapter() { SetInflectorAdapter(BuiltinInflector{}) }

// BuiltinInflector is a rule-based English singularizer. Rules are adapted
// from ActiveSupport's defaults; ordering is most-specific-first.
type BuiltinInflector struct{}

var inflectorIrregulars = map[string]string{
	"people":   "person",
	"children": "child",
	"men":      "man",
	"women":    "woman",
	"mice":     "mouse",
	"geese":    "goose",
	"oxen":     "ox",
	"feet":     "foot",
	"teeth":    "tooth",
	"lives":    "life",
	"wives":    "wife",
	"moves":    "move",
	"zombies":  "zombie",
	"indices":  "index",
	"vertices": "vertex",
	"leaves":   "leaf",
	"calves":   "calf",
	"halves":   "half",
	"loaves":   "loaf",
	"hooves":   "hoof",
}

var inflectorUncountable = map[string]struct{}{
	"news": {}, "fish": {}, "sheep": {}, "deer": {}, "series": {}, "species": {},
	"equipment": {}, "information": {}, "money": {}, "rice": {}, "jeans": {},
	"police": {}, "data": {}, "media": {},
}

type inflectorRule struct {
	re   *regexp.Regexp
	repl string
}

var inflectorRules = []inflectorRule{
	{regexp.MustCompile(`(?i)(quiz)zes$`), "${1}"},
	{regexp.MustCompile(`(?i)(matri|appendi)ces$`), "${1}x"},
	{regexp.MustCompile(`(?i)(ox)en$`), "${1}"},
	{regexp.MustCompile(`(?i)(alias|status)(es)?$`), "${1}"},
	{regexp.MustCompile(`(?i)(octop|vir)(us|i)$`), "${1}us"},
	{regexp.MustCompile(`(?i)(cris|ax|test)es$`), "${1}is"},
	{regexp.MustCompile(`(?i)(shoe)s$`), "${1}"},
	{regexp.MustCompile(`(?i)(bus)(es)?$`), "${1}"},
	{regexp.MustCompile(`(?i)([ml])ice$`), "${1}ouse"},
	{regexp.MustCompile(`(?i)(x|ch|ss|sh)es$`), "${1}"},
	{regexp.MustCompile(`(?i)(m)ovies$`), "${1}ovie"},
	{regexp.MustCompile(`(?i)(s)eries$`), "${1}eries"},
	{regexp.MustCompile(`(?i)([^aeiouy]|qu)ies$`), "${1}y"},
	{regexp.MustCompile(`(?i)([lr])ves$`), "${1}f"},
	{regexp.MustCompile(`(?i)(tive)s$`), "${1}"},
	{regexp.MustCompile(`(?i)(hive)s$`), "${1}"},
	{regexp.MustCompile(`(?i)([^f])ves$`), "${1}fe"},
	{regexp.MustCompile(`(?i)((a)naly|(b)a|(d)iagno|(p)arenthe|(p)rogno|(s)ynop|(t)he)ses$`), "${1}sis"},
	{regexp.MustCompile(`(?i)([ti])a$`), "${1}um"},
	{regexp.MustCompile(`(?i)(n)ews$`), "${1}ews"},
	{regexp.MustCompile(`(?i)(o)es$`), "${1}"},
	{regexp.MustCompile(`(?i)(ss)$`), "${1}"},
	{regexp.MustCompile(`(?i)s$`), ""},
}

func (BuiltinInflector) Singularize(word string) string {
	if word == "" {
		return word
	}
	lower := strings.ToLower(word)
	if _, ok := inflectorUncountable[lower]; ok {
		return word
	}
	if irr, ok := inflectorIrregulars[lower]; ok {
		return preserveCase(word, irr)
	}
	for _, r := range inflectorRules {
		if r.re.MatchString(word) {
			return r.re.ReplaceAllString(word, r.repl)
		}
	}
	return word
}

func preserveCase(original, lowered string) string {
	if original == strings.ToUpper(original) {
		return strings.ToUpper(lowered)
	}
	runes := []rune(original)
	if len(runes) > 0 && unicode.IsUpper(runes[0]) {
		r := []rune(lowered)
		if len(r) > 0 {
			r[0] = unicode.ToUpper(r[0])
		}
		return string(r)
	}
	return lowered
}
