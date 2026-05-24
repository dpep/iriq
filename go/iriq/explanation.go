package iriq

import "strings"

// Explain returns a per-segment explanation for an input string.
func Explain(input string) ([]SegmentHint, error) {
	iri, err := Parse(input)
	if err != nil {
		return nil, err
	}
	return ExplainIdentifier(iri, DefaultClassifier), nil
}

// ExplainIdentifier mirrors Ruby's Explanation.explain for a pre-parsed IRI.
func ExplainIdentifier(iri *Identifier, c *SegmentClassifier) []SegmentHint {
	if c == nil {
		c = DefaultClassifier
	}
	if iri.IsURN() {
		return explainURN(iri, c)
	}
	return DeriveHints(iri.PathSegments, c)
}

func explainURN(iri *Identifier, c *SegmentClassifier) []SegmentHint {
	if iri.NSS == "" {
		return []SegmentHint{}
	}
	var parts []string
	if strings.Contains(iri.NSS, ":") {
		ns, val, _ := strings.Cut(iri.NSS, ":")
		parts = []string{ns, val}
	} else {
		parts = []string{iri.NSS}
	}
	return DeriveHints(parts, c)
}
