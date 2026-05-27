package iriq

import (
	"fmt"
	"sort"
	"strings"
)

// TraceRow is one row of an annotated normalization trace — either a
// path segment or a query parameter. Name is empty for path rows;
// populated (and prepended in display) for query rows.
type TraceRow struct {
	Name   string      `json:"name,omitempty"`
	Value  string      `json:"value"`
	Type   SegmentType `json:"type"`
	Output string      `json:"output"`
	Notes  []string    `json:"notes"`
}

// TraceResult is the full annotated trace for an identifier, mirroring
// Ruby's Trace.for return shape.
type TraceResult struct {
	Input      string     `json:"input"`
	Normalized string     `json:"normalized"`
	Scheme     string     `json:"scheme,omitempty"`
	Host       string     `json:"host,omitempty"`
	Port       int        `json:"port,omitempty"`
	Path       []TraceRow `json:"path"`
	Query      []TraceRow `json:"query,omitempty"`
}

// Trace returns an annotated trace explaining how the input gets
// normalized — segment by segment, with notes for each non-obvious
// transformation (currency upcase, IP umbrella, hint suppression,
// canonical date, param-name lift).
func Trace(input string) (*TraceResult, error) {
	iri, err := Parse(input)
	if err != nil {
		return nil, err
	}
	return TraceIdentifier(iri, DefaultClassifier, true), nil
}

// TraceIdentifier produces a trace for a pre-parsed identifier.
func TraceIdentifier(iri *Identifier, c *SegmentClassifier, hints bool) *TraceResult {
	if c == nil {
		c = DefaultClassifier
	}
	out := &TraceResult{
		Input:      iri.Canonical(),
		Normalized: NormalizeIdentifier(iri, c, hints),
		Scheme:     iri.Scheme,
		Host:       iri.Host,
		Port:       iri.Port,
		Path:       []TraceRow{},
	}

	if iri.IsURN() {
		out.Path = tracePath(urnParts(iri), c, hints)
		return out
	}

	out.Path = tracePath(iri.PathSegments, c, hints)
	if iri.QueryParams != nil && iri.QueryParams.Len() > 0 {
		out.Query = traceQuery(iri.QueryParams, c)
	}
	return out
}

func urnParts(iri *Identifier) []string {
	if iri.NSS == "" {
		return nil
	}
	if strings.Contains(iri.NSS, ":") {
		ns, val, _ := strings.Cut(iri.NSS, ":")
		return []string{ns, val}
	}
	return []string{iri.NSS}
}

func tracePath(segments []string, c *SegmentClassifier, hints bool) []TraceRow {
	if len(segments) == 0 {
		return []TraceRow{}
	}
	entries := DeriveHints(segments, c)
	rows := make([]TraceRow, len(entries))
	for i, e := range entries {
		rows[i] = traceSegmentRow(e, segments, i, c, hints)
	}
	return rows
}

func traceSegmentRow(entry SegmentHint, segments []string, idx int, c *SegmentClassifier, hints bool) TraceRow {
	row := TraceRow{Value: entry.Value, Type: entry.Type, Notes: []string{}}

	if !entry.Variable {
		row.Output = entry.Value
		return row
	}

	if entry.Type == TypeDate {
		if canon := CanonicalDate(entry.Value); canon != "" {
			row.Output = canon
			if canon != entry.Value {
				row.Notes = append(row.Notes, fmt.Sprintf("canonical date (%s → %s)", entry.Value, canon))
			}
			return row
		}
	}
	if entry.Type == TypeCurrency {
		if canon := CanonicalCurrency(entry.Value); canon != "" {
			row.Output = canon
			if canon != entry.Value {
				row.Notes = append(row.Notes, fmt.Sprintf("currency upcase (%s → %s)", entry.Value, canon))
			}
			return row
		}
	}

	display := DisplayType(entry.Type)
	if entry.Type == TypeIPv4 || entry.Type == TypeIPv6 {
		row.Notes = append(row.Notes, fmt.Sprintf("ip umbrella collapse (%s → ip)", entry.Type))
	}

	if hints && entry.Hint != "" {
		row.Output = "{" + entry.Hint + "}"
		return row
	}

	// Semantic types skip the noun-singularize hint. Surface the
	// would-be hint so users see WHY {version} is preferred over {api_id}.
	if hints {
		if _, eligible := hintEligibleTypes[entry.Type]; !eligible {
			if would := wouldBeHint(segments, idx, entry.Type, c); would != "" {
				row.Notes = append(row.Notes, fmt.Sprintf("semantic type — surfaced as {%s}, not {%s}", display, would))
			}
		}
	}

	row.Output = "{" + display + "}"
	return row
}

func wouldBeHint(segments []string, idx int, t SegmentType, c *SegmentClassifier) string {
	if idx == 0 {
		return ""
	}
	prev := segments[idx-1]
	if c.Classify(prev) != TypeLiteral {
		return ""
	}
	base := Singularize(prev)
	if t == TypeUUID {
		return base + "_uuid"
	}
	return base + "_id"
}

func traceQuery(params *OrderedMap, c *SegmentClassifier) []TraceRow {
	keys := params.Keys()
	sort.Strings(keys)
	rows := make([]TraceRow, 0, len(keys))
	for _, k := range keys {
		v, _ := params.Get(k)
		baseType := c.Classify(v)
		notes := []string{}
		effective := baseType

		if hint := ParamNameHint(k, baseType); hint != "" {
			effective = hint
			notes = append(notes, fmt.Sprintf("param-name hint (`%s=`) lifted %s → %s", k, baseType, hint))
		}

		output := renderTraceQueryValue(v, effective, &notes, c)
		rows = append(rows, TraceRow{Name: k, Value: v, Type: effective, Output: output, Notes: notes})
	}
	return rows
}

func renderTraceQueryValue(value string, t SegmentType, notes *[]string, c *SegmentClassifier) string {
	if t == TypeDate {
		if canon := CanonicalDate(value); canon != "" {
			if canon != value {
				*notes = append(*notes, fmt.Sprintf("canonical date (%s → %s)", value, canon))
			}
			return canon
		}
	}
	if t == TypeCurrency {
		if canon := CanonicalCurrency(value); canon != "" {
			if canon != value {
				*notes = append(*notes, fmt.Sprintf("currency upcase (%s → %s)", value, canon))
			}
			return canon
		}
	}
	if c.Variable(t) {
		if t == TypeIPv4 || t == TypeIPv6 {
			*notes = append(*notes, fmt.Sprintf("ip umbrella collapse (%s → ip)", t))
		}
		return "{" + DisplayType(t) + "}"
	}
	return value
}
