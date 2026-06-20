package iriq

import (
	"fmt"
	"regexp"
	"strings"
)

// SynthesizedRecognizer is a Recognizer built dynamically from a
// learned-prefix pattern.
//
// Used by Corpus.ActivateProposal to promote a RecognizerProposal into a
// live Recognizer that the classifier ensemble consults. Same shape as
// the built-in Recognizers (UUIDRecognizer, DateRecognizer,
// IntegerRecognizer) but the pattern + type are supplied at construction
// rather than compiled-in.
//
//   r := NewSynthesizedRecognizer("ghp_", "ghp", SpecificitySemantic)
//   r.Try("ghp_abcdef123")  // → {Type: ghp, Confidence: 1.0, Specificity: 1.0}, true
//
// Pattern: `<prefix><[A-Za-z0-9]+>` — anchored, alphanumeric suffix only.
// Matches the same shape PrefixUnderscoreIdStrategy proposes from, so
// round-trip (propose → activate → reinfer) reclassifies the same
// values the proposal was derived from.
type SynthesizedRecognizer struct {
	Prefix      string
	Type        SegmentType
	Specificity float64
	pattern     *regexp.Regexp
}

// NewSynthesizedRecognizer builds a Recognizer for the given prefix.
// Specificity defaults to SpecificitySemantic when zero — learned prefixes
// are very specific by construction.
func NewSynthesizedRecognizer(prefix, typeName string, specificity float64) *SynthesizedRecognizer {
	if prefix == "" {
		panic("SynthesizedRecognizer: prefix must be non-empty")
	}
	if specificity == 0 {
		specificity = SpecificitySemantic
	}
	pattern := regexp.MustCompile("^" + regexp.QuoteMeta(prefix) + "[A-Za-z0-9]+$")
	return &SynthesizedRecognizer{
		Prefix:      prefix,
		Type:        SegmentType(typeName),
		Specificity: specificity,
		pattern:     pattern,
	}
}

// SynthesizedRecognizerFromProposal mirrors the Ruby convenience
// constructor — pulls prefix + suggested_type out of the proposal.
func SynthesizedRecognizerFromProposal(p RecognizerProposal) *SynthesizedRecognizer {
	return NewSynthesizedRecognizer(p.Prefix, p.SuggestedType, SpecificitySemantic)
}

// Try implements Recognizer.
func (s *SynthesizedRecognizer) Try(segment string) (Verdict, bool) {
	if !strings.HasPrefix(segment, s.Prefix) || !s.pattern.MatchString(segment) {
		return Verdict{}, false
	}
	return Verdict{Type: s.Type, Confidence: 1.0, Specificity: s.Specificity}, true
}

// Dump returns the serialized form for persistence in a Corpus.
func (s *SynthesizedRecognizer) Dump() map[string]any {
	return map[string]any{
		"prefix":      s.Prefix,
		"type":        string(s.Type),
		"specificity": s.Specificity,
	}
}

// SynthesizedRecognizerFromDump reconstructs a Recognizer from the
// storage form produced by Dump().
func SynthesizedRecognizerFromDump(dump map[string]any) (*SynthesizedRecognizer, error) {
	prefix, ok := dump["prefix"].(string)
	if !ok || prefix == "" {
		return nil, fmt.Errorf("SynthesizedRecognizer: missing/invalid prefix in dump")
	}
	typeStr, _ := dump["type"].(string)
	if typeStr == "" {
		return nil, fmt.Errorf("SynthesizedRecognizer: missing type in dump")
	}
	spec, _ := dump["specificity"].(float64)
	return NewSynthesizedRecognizer(prefix, typeStr, spec), nil
}
