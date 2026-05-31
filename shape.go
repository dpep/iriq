package iriq

import "strings"

// Shape is a structured route shape — an ordered list of typed segment
// entries plus rendering methods producing the various string forms
// (placeholder, canonical-dates, raw-types, etc.).
//
// Replaces the string-as-data convention where PathShape's string output
// was the only carrier of shape information. Structured Shape makes:
//   - downstream consumers cheap (they iterate Entries instead of
//     re-deriving from segments + classifier)
//   - shape identity explicit (structural equality via Render, not
//     string match)
//   - multiple renderings free (canonical dates, hints on/off, raw types
//     vs hinted) without re-walking segments
//
// The cluster identity layer still uses string keys for storage; a
// follow-up step migrates Cluster equality to be Shape-driven.
type Shape struct {
	Entries []SegmentHint
}

// ShapeFromSegments builds a Shape from raw path segments using the given
// classifier. Pass nil for the default classifier.
func ShapeFromSegments(segments []string, classifier *SegmentClassifier) Shape {
	if classifier == nil {
		classifier = DefaultClassifier
	}
	return Shape{Entries: DeriveHints(segments, classifier)}
}

// ShapeFromEntries wraps an already-derived []SegmentHint into a Shape.
func ShapeFromEntries(entries []SegmentHint) Shape {
	return Shape{Entries: entries}
}

// ShapeRenderOptions controls rendering. Zero value renders placeholders
// with hints enabled and no canonicalization.
type ShapeRenderOptions struct {
	// HintsOff disables hint placeholders; when true, variable segments
	// render as their display type (e.g. {integer}) rather than the
	// noun-singularized hint ({user_id}).
	HintsOff bool
	// CanonicalDates renders date-typed segments in canonical ISO form
	// (2024/01/15 → 2024-01-15) instead of as {date}.
	CanonicalDates bool
	// CanonicalCurrencies renders currency-typed segments upcased to
	// ISO 4217 (usd → USD) instead of as {currency}.
	CanonicalCurrencies bool
}

// Render produces the string form of the Shape per the given options. The
// zero-value options produce the canonical placeholder form ("/users/{user_id}").
func (s Shape) Render(opts ShapeRenderOptions) string {
	if len(s.Entries) == 0 {
		return "/"
	}
	var b strings.Builder
	for _, e := range s.Entries {
		b.WriteByte('/')
		b.WriteString(renderShapeEntry(e, opts))
	}
	return b.String()
}

// String is the canonical placeholder rendering. Two Shapes that produce
// the same String() are considered equal — see Equal.
func (s Shape) String() string {
	return s.Render(ShapeRenderOptions{})
}

// Equal reports whether two Shapes have the same canonical rendering.
// /users/1 and /users/999 are equal; /users/1 and /posts/1 are not.
func (s Shape) Equal(other Shape) bool {
	return s.String() == other.String()
}

func renderShapeEntry(e SegmentHint, opts ShapeRenderOptions) string {
	if !e.Variable {
		return e.Value
	}
	if opts.CanonicalDates && e.Type == TypeDate {
		if canon := CanonicalDate(e.Value); canon != "" {
			return canon
		}
	}
	if opts.CanonicalCurrencies && e.Type == TypeCurrency {
		if canon := CanonicalCurrency(e.Value); canon != "" {
			return canon
		}
	}
	if !opts.HintsOff && e.Hint != "" {
		return "{" + e.Hint + "}"
	}
	return "{" + DisplayType(e.Type) + "}"
}
