package iriq

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

func unicodeIsLetterOrDigit(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsDigit(r) || unicode.IsMark(r)
}

func lastRune(s string) rune {
	r, _ := utf8.DecodeLastRuneInString(s)
	return r
}

func trimLastRune(s string) string {
	_, n := utf8.DecodeLastRuneInString(s)
	if n == 0 {
		return s
	}
	return s[:len(s)-n]
}

// runeCount counts occurrences of a rune in a string.
func runeCount(s string, target rune) int {
	if target < utf8.RuneSelf {
		return strings.Count(s, string(target))
	}
	n := 0
	for _, r := range s {
		if r == target {
			n++
		}
	}
	return n
}
