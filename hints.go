package iriq

// SegmentHint is an annotated segment: its raw value, its classifier-derived
// type, whether it's variable, and a RESTful hint when one applies (e.g.
// "user_id" derived from /users/123).
type SegmentHint struct {
	Value    string
	Type     SegmentType
	Variable bool
	Hint     string
}

// DeriveHints walks a segment list and annotates each entry. A variable
// segment that follows a literal one gets a hint built from the previous
// literal singularized + "_id" (or "_uuid" for UUID-typed segments).
func DeriveHints(segments []string, c *SegmentClassifier) []SegmentHint {
	if c == nil {
		c = DefaultClassifier
	}
	out := make([]SegmentHint, len(segments))
	for i, seg := range segments {
		t := c.Classify(seg)
		variable := c.Variable(t)
		out[i] = SegmentHint{
			Value:    seg,
			Type:     t,
			Variable: variable,
			Hint:     hintFor(segments, i, t, variable, c),
		}
	}
	return out
}

func hintFor(segments []string, i int, t SegmentType, variable bool, c *SegmentClassifier) string {
	if !variable || i == 0 {
		return ""
	}
	prev := segments[i-1]
	if c.Classify(prev) != TypeLiteral {
		return ""
	}
	base := Singularize(prev)
	suffix := "_id"
	if t == TypeUUID {
		suffix = "_uuid"
	}
	return base + suffix
}
