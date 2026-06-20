package iriq

import (
	"sort"
	"strings"
)

// NormalizationEvidence is the interface Normalizer uses to render the
// path and query portions of an Identifier. Two implementations ship:
//
//   NullEvidence — classifier-only behavior (mechanical Normalize)
//   *Corpus      — uses observed Position / Cluster stats when available
//
// When evidence is nil at the Normalize call site, Normalizer uses
// NullEvidence{}. Callers that hold a Corpus can pass it via
// NormalizeWithEvidence to opt into corpus-informed rendering.
type NormalizationEvidence interface {
	RenderPath(iri *Identifier, c *SegmentClassifier, hints bool) string
	RenderQuery(iri *Identifier, c *SegmentClassifier) string
}

// Normalize parses input and returns a canonical, shape-aware string
// suitable for grouping/diffing.
func Normalize(input string) (string, error) {
	return NormalizeWith(input, DefaultClassifier, true)
}

func NormalizeWith(input string, c *SegmentClassifier, hints bool) (string, error) {
	iri, err := Parse(input)
	if err != nil {
		return "", err
	}
	return NormalizeIdentifier(iri, c, hints), nil
}

// NormalizeIdentifier renders an Identifier using NullEvidence (the
// classifier-only mechanical path).
func NormalizeIdentifier(iri *Identifier, c *SegmentClassifier, hints bool) string {
	return NormalizeIdentifierWithEvidence(iri, c, hints, NullEvidence{})
}

// NormalizeWithEvidence parses input and renders it via the given evidence
// source. Pass *Corpus for corpus-informed rendering.
func NormalizeWithEvidence(input string, c *SegmentClassifier, hints bool, ev NormalizationEvidence) (string, error) {
	iri, err := Parse(input)
	if err != nil {
		return "", err
	}
	return NormalizeIdentifierWithEvidence(iri, c, hints, ev), nil
}

// NormalizeIdentifierWithEvidence is the single normalizer entry point —
// dispatches the path and query rendering through the evidence source.
// URN handling stays inline since it isn't a path/query structure.
func NormalizeIdentifierWithEvidence(iri *Identifier, c *SegmentClassifier, hints bool, ev NormalizationEvidence) string {
	if c == nil {
		c = DefaultClassifier
	}
	if ev == nil {
		ev = NullEvidence{}
	}
	if iri.IsURN() {
		return normalizeURN(iri, c, hints)
	}

	var b strings.Builder
	if iri.Scheme != "" {
		b.WriteString(iri.Scheme)
		b.WriteString("://")
	}
	if iri.Host != "" {
		b.WriteString(iri.Host)
	}
	if iri.Port != 0 {
		b.WriteByte(':')
		b.WriteString(itoa(iri.Port))
	}
	b.WriteString(ev.RenderPath(iri, c, hints))
	if iri.QueryParams.Len() > 0 {
		b.WriteByte('?')
		b.WriteString(ev.RenderQuery(iri, c))
	}
	return b.String()
}

func normalizeURN(iri *Identifier, c *SegmentClassifier, hints bool) string {
	if !(iri.Scheme == "urn" && iri.NSS != "" && strings.Contains(iri.NSS, ":")) {
		return iri.Canonical()
	}
	ns, value, _ := strings.Cut(iri.NSS, ":")
	entries := DeriveHints([]string{ns, value}, c)
	entry := entries[len(entries)-1]
	var shaped string
	switch {
	case entry.Type == TypeDate && CanonicalDate(entry.Value) != "":
		shaped = CanonicalDate(entry.Value)
	case entry.Type == TypeCurrency && CanonicalCurrency(entry.Value) != "":
		shaped = CanonicalCurrency(entry.Value)
	case entry.Variable:
		placeholder := entry.Hint
		if !hints || placeholder == "" {
			placeholder = DisplayType(entry.Type)
		}
		shaped = "{" + placeholder + "}"
	default:
		shaped = entry.Value
	}
	return "urn:" + ns + ":" + shaped
}

// NullEvidence implements NormalizationEvidence with no corpus signal —
// classifier-only rendering, equivalent to the previous mechanical path.
type NullEvidence struct{}

func (NullEvidence) RenderPath(iri *Identifier, c *SegmentClassifier, hints bool) string {
	ps := &PathShape{Classifier: c, Hints: hints, CanonicalDates: true, CanonicalCurrencies: true}
	return ps.For(iri.PathSegments)
}

func (NullEvidence) RenderQuery(iri *Identifier, c *SegmentClassifier) string {
	return shapeQuery(iri.QueryParams, c)
}

func shapeQuery(params *OrderedMap, c *SegmentClassifier) string {
	keys := params.Keys()
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		v, _ := params.Get(k)
		t := c.Classify(v)
		// Param-name hint can lift a generic literal/opaque_id/slug into a
		// semantic type — `?phone=unknown` becomes `{phone}`.
		if hint := ParamNameHint(k, t); hint != "" {
			t = hint
		}
		var shaped string
		switch {
		case t == TypeDate:
			if canon := CanonicalDate(v); canon != "" {
				shaped = canon
			} else {
				shaped = "{" + DisplayType(t) + "}"
			}
		case t == TypeCurrency:
			if canon := CanonicalCurrency(v); canon != "" {
				shaped = canon
			} else {
				shaped = "{" + DisplayType(t) + "}"
			}
		case c.Variable(t):
			shaped = "{" + DisplayType(t) + "}"
		default:
			shaped = v
		}
		parts = append(parts, k+"="+shaped)
	}
	return strings.Join(parts, "&")
}
