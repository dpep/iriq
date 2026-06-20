package iriq

import (
	"regexp"
	"strings"
	"unicode/utf8"
)

// Extractor pulls IRIs out of free text. Scheme-anchored — only URLs whose
// scheme appears explicitly are extracted; scheme-less hosts like "foo.com/x"
// are extracted only when SchemeLess is true (default).
type Extractor struct {
	SchemeLess bool
}

func NewExtractor() *Extractor { return &Extractor{SchemeLess: true} }

var (
	extractorSchemes        = []string{"https", "http", "ftp", "wss", "ws"}
	extractorSchemelessTLDs = []string{"com", "org", "net", "io", "ai", "dev", "co", "app", "gov", "edu"}

	// CJK/Unicode brackets and curly quotes that almost always terminate a URL
	// in source text. Mirrors NON_ASCII_BOUNDARY in the Ruby implementation.
	extractorNonASCIIBoundary = uniqueRunes(
		"」』）】〉》〕〗〙〛｠｝］＞" +
			"「『（【〈《〔〖〘〚｟｛［＜" +
			"“”‘’„‟‚«»‹›",
	)
)

// extractorURLChars is the character class allowed inside an extracted URL:
// everything except ASCII whitespace, angle brackets, quotes, backtick,
// comma, and the listed Unicode boundary chars.
var extractorURLChars = `[^\s<>"'` + "`" + `,` + regexpCharClassEscape(extractorNonASCIIBoundary) + `]+`

var (
	// Scheme-anchored only (used when SchemeLess is false).
	candidateRE = regexp.MustCompile(
		`(?:` +
			`(?i:` + strings.Join(extractorSchemes, "|") + `)://` + extractorURLChars +
			`|` +
			`urn:[a-zA-Z0-9][a-zA-Z0-9\-]{0,30}:` + extractorURLChars +
			`)`,
	)

	// Combined pattern: scheme-anchored OR urn OR scheme-less.
	combinedRE = regexp.MustCompile(
		`(?:` +
			`(?i:` + strings.Join(extractorSchemes, "|") + `)://` + extractorURLChars +
			`|` +
			`urn:[a-zA-Z0-9][a-zA-Z0-9\-]{0,30}:` + extractorURLChars +
			`|` +
			`(?:[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+(?i:` +
			strings.Join(extractorSchemelessTLDs, "|") + `)/` + extractorURLChars +
			`)`,
	)

	trailingPunctRE = regexp.MustCompile(`[.,;:!?'"\x{2018}\x{2019}\x{201C}\x{201D}]+$`)
)

var bracketPairs = map[rune]rune{')': '(', ']': '[', '}': '{'}

// Extract scans text and returns parsed IRIs in source order. Unparseable
// candidates are silently dropped.
func (e *Extractor) Extract(text string) []*Identifier {
	if text == "" {
		return nil
	}
	pattern := candidateRE
	if e.SchemeLess {
		pattern = combinedRE
	}
	out := make([]*Identifier, 0, 4)
	for _, loc := range pattern.FindAllStringIndex(text, -1) {
		if !leftBoundaryOK(text, loc[0], e.SchemeLess) {
			continue
		}
		candidate := text[loc[0]:loc[1]]
		trimmed := trimCandidate(candidate)
		if trimmed == "" {
			continue
		}
		iri, err := Parse(trimmed)
		if err != nil {
			continue
		}
		out = append(out, iri)
	}
	return out
}

// ExtractStrings is like Extract but returns canonical strings, deduplicated,
// preserving first-seen order.
func (e *Extractor) ExtractStrings(text string) []string {
	seen := map[string]struct{}{}
	out := make([]string, 0)
	for _, iri := range e.Extract(text) {
		c := iri.Canonical()
		if _, ok := seen[c]; ok {
			continue
		}
		seen[c] = struct{}{}
		out = append(out, c)
	}
	return out
}

// leftBoundaryOK enforces what Ruby's negative lookbehind (?<![\w/.@]) or
// (?<![\w/]) does. RE2 has no lookbehind, so we re-check after the match.
//
// Scheme-only mode uses [\w/]; combined mode also excludes . and @ to prevent
// extracting from inside emails and longer hostnames like "a.foo.com".
func leftBoundaryOK(text string, start int, schemeless bool) bool {
	if start == 0 {
		return true
	}
	r, _ := utf8.DecodeLastRuneInString(text[:start])
	if r == utf8.RuneError {
		return true
	}
	if isWordRune(r) {
		return false
	}
	if r == '/' {
		return false
	}
	if schemeless && (r == '.' || r == '@') {
		return false
	}
	return true
}

// isWordRune mirrors Ruby's Unicode-aware \w in /xu mode: letters, marks,
// numbers, and underscore.
func isWordRune(r rune) bool {
	if r == '_' {
		return true
	}
	return unicodeIsLetterOrDigit(r)
}

func trimCandidate(candidate string) string {
	s := candidate
	for {
		before := s
		s = trailingPunctRE.ReplaceAllString(s, "")
		for close, open := range bracketPairs {
			for len(s) > 0 && lastRune(s) == close && runeCount(s, close) > runeCount(s, open) {
				s = trimLastRune(s)
			}
		}
		if s == before {
			return s
		}
	}
}

func uniqueRunes(s string) string {
	seen := map[rune]struct{}{}
	var out []rune
	for _, r := range s {
		if _, ok := seen[r]; ok {
			continue
		}
		seen[r] = struct{}{}
		out = append(out, r)
	}
	return string(out)
}

// regexpCharClassEscape escapes the small set of characters that have special
// meaning inside an RE2 character class: ], \, ^, -.
func regexpCharClassEscape(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch r {
		case ']', '\\', '^', '-':
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}
