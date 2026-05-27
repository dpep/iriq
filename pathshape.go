package iriq

import "strings"

// PathShape converts a sequence of path segments into a route-shape string by
// replacing variable segments with {hint} placeholders (or {type} if hints
// are disabled / no hint is available).
//
// With CanonicalDates set, date-typed segments render in canonical ISO form
// (2024/01/15 → 2024-01-15) instead of as a {date} placeholder.
// CanonicalCurrencies does the same for currency codes (`usd` → `USD`).
// Used by the normalizer for display output; the clusterer keeps the
// placeholder form so dated/currency routes still group together.
type PathShape struct {
	Classifier          *SegmentClassifier
	Hints               bool
	CanonicalDates      bool
	CanonicalCurrencies bool
}

// NewPathShape returns a PathShape with the default classifier and hints on.
func NewPathShape() *PathShape {
	return &PathShape{Classifier: DefaultClassifier, Hints: true}
}

// For renders the shape for a segment list.
func (p *PathShape) For(segments []string) string {
	if len(segments) == 0 {
		return "/"
	}
	c := p.Classifier
	if c == nil {
		c = DefaultClassifier
	}
	return p.FromEntries(DeriveHints(segments, c))
}

// FromEntries builds a shape string from already-derived SegmentHints. Used by
// the corpus to avoid re-deriving entries when both raw and hinted variants
// are needed.
func (p *PathShape) FromEntries(entries []SegmentHint) string {
	if len(entries) == 0 {
		return "/"
	}
	var b strings.Builder
	for _, e := range entries {
		b.WriteByte('/')
		b.WriteString(p.shapeToken(e))
	}
	return b.String()
}

func (p *PathShape) shapeToken(e SegmentHint) string {
	if !e.Variable {
		return e.Value
	}
	if p.CanonicalDates && e.Type == TypeDate {
		if canon := CanonicalDate(e.Value); canon != "" {
			return canon
		}
	}
	if p.CanonicalCurrencies && e.Type == TypeCurrency {
		if canon := CanonicalCurrency(e.Value); canon != "" {
			return canon
		}
	}
	if p.Hints {
		if e.Hint != "" {
			return "{" + e.Hint + "}"
		}
		return "{" + DisplayType(e.Type) + "}"
	}
	return "{" + DisplayType(e.Type) + "}"
}

// PathShapeFor is the convenience constructor + invocation matching Ruby's
// PathShape.for(...).
func PathShapeFor(segments []string, hints bool) string {
	return (&PathShape{Classifier: DefaultClassifier, Hints: hints}).For(segments)
}
