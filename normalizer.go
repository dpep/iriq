package iriq

import (
	"sort"
	"strings"
)

// Normalize parses input (or accepts a pre-parsed Identifier) and returns a
// canonical, shape-aware string suitable for grouping/diffing.
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

// NormalizeIdentifier mirrors Ruby's Normalizer.normalize_identifier.
func NormalizeIdentifier(iri *Identifier, c *SegmentClassifier, hints bool) string {
	if c == nil {
		c = DefaultClassifier
	}
	if iri.IsURN() {
		if iri.Scheme == "urn" && iri.NSS != "" && strings.Contains(iri.NSS, ":") {
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
		return iri.Canonical()
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
	ps := &PathShape{Classifier: c, Hints: hints, CanonicalDates: true, CanonicalCurrencies: true}
	b.WriteString(ps.For(iri.PathSegments))
	if iri.QueryParams.Len() > 0 {
		b.WriteByte('?')
		b.WriteString(shapeQuery(iri.QueryParams, c))
	}
	return b.String()
}

func shapeQuery(params *OrderedMap, c *SegmentClassifier) string {
	keys := params.Keys()
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		v, _ := params.Get(k)
		t := c.Classify(v)
		// Param-name hint can lift a generic literal/opaque_id/slug into
		// a semantic type — `?phone=unknown` becomes `{phone}`.
		if hint := ParamNameHint(k, t); hint != "" {
			t = hint
		}
		var shaped string
		if t == TypeDate {
			if canon := CanonicalDate(v); canon != "" {
				shaped = canon
			} else {
				shaped = "{" + DisplayType(t) + "}"
			}
		} else if t == TypeCurrency {
			if canon := CanonicalCurrency(v); canon != "" {
				shaped = canon
			} else {
				shaped = "{" + DisplayType(t) + "}"
			}
		} else if c.Variable(t) {
			shaped = "{" + DisplayType(t) + "}"
		} else {
			shaped = v
		}
		parts = append(parts, k+"="+shaped)
	}
	return strings.Join(parts, "&")
}
