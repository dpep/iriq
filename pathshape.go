package iriq

// PathShape renders a route-shape string. As of v0.16 this is a thin
// wrapper around Shape.Render — kept for back-compat with callers that
// still want to go from segments to a string in one call.
//
// With CanonicalDates set, date-typed segments render in canonical ISO
// form (2024/01/15 → 2024-01-15) instead of as {date}. CanonicalCurrencies
// does the same for currency codes (`usd` → `USD`). Used by the
// normalizer for display output.
//
// For new code, prefer constructing a Shape directly via ShapeFromSegments
// or ShapeFromEntries and calling Render with the desired options.
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
	return ShapeFromSegments(segments, p.Classifier).Render(p.renderOpts())
}

// FromEntries builds a shape string from already-derived SegmentHints. Used
// by the corpus to avoid re-deriving entries when both raw and hinted
// variants are needed.
func (p *PathShape) FromEntries(entries []SegmentHint) string {
	return ShapeFromEntries(entries).Render(p.renderOpts())
}

func (p *PathShape) renderOpts() ShapeRenderOptions {
	return ShapeRenderOptions{
		HintsOff:            !p.Hints,
		CanonicalDates:      p.CanonicalDates,
		CanonicalCurrencies: p.CanonicalCurrencies,
	}
}

// PathShapeFor is the convenience constructor + invocation matching Ruby's
// PathShape.for(...).
func PathShapeFor(segments []string, hints bool) string {
	return (&PathShape{Classifier: DefaultClassifier, Hints: hints}).For(segments)
}
