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
// canonical date, param-name lift). The string notes are rendered from
// structured Evidence values; callers that want the structured form
// can use EvidenceFor.
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

// EvidenceFor returns the structured Evidence list for input. Each
// segment + query param contributes one classification Evidence
// (source=recognizer) plus zero or more transformation Evidence records
// (policy / neighbor sources). Position + Cluster Evidence aren't
// emitted here — they belong to corpus-informed trace, which a future
// step lands.
func EvidenceFor(input string) ([]Evidence, error) {
	iri, err := Parse(input)
	if err != nil {
		return nil, err
	}
	return EvidenceForIdentifier(iri, DefaultClassifier, true), nil
}

// EvidenceForIdentifier is the Identifier-taking variant of EvidenceFor.
func EvidenceForIdentifier(iri *Identifier, c *SegmentClassifier, hints bool) []Evidence {
	if c == nil {
		c = DefaultClassifier
	}
	var records []Evidence
	segments := iri.PathSegments
	if iri.IsURN() {
		segments = urnParts(iri)
	}
	entries := DeriveHints(segments, c)
	for i, entry := range entries {
		records = append(records, segmentEvidence(entry, segments, i, c, hints)...)
	}
	if !iri.IsURN() && iri.QueryParams != nil && iri.QueryParams.Len() > 0 {
		keys := iri.QueryParams.Keys()
		sortedKeys := append([]string(nil), keys...)
		sort.Strings(sortedKeys)
		for _, k := range sortedKeys {
			v, _ := iri.QueryParams.Get(k)
			records = append(records, queryParamEvidence(k, v, c)...)
		}
	}
	return records
}

// ── Evidence builders ────────────────────────────────────────────────

func segmentEvidence(entry SegmentHint, segments []string, idx int, c *SegmentClassifier, hints bool) []Evidence {
	records := []Evidence{
		SegmentEvidence(idx, entry.Value, EvidenceRecognizer, map[string]any{
			"type":     entry.Type,
			"variable": entry.Variable,
			"hint":     entry.Hint,
		}),
	}

	if !entry.Variable {
		return records
	}

	if entry.Type == TypeDate {
		if canon := CanonicalDate(entry.Value); canon != "" {
			if canon != entry.Value {
				records = append(records, SegmentEvidence(idx, entry.Value, EvidencePolicy, map[string]any{
					"rule": "canonical_date", "before": entry.Value, "after": canon,
				}).WithNotes(fmt.Sprintf("canonical date (%s → %s)", entry.Value, canon)))
			}
			return records
		}
	}
	if entry.Type == TypeCurrency {
		if canon := CanonicalCurrency(entry.Value); canon != "" {
			if canon != entry.Value {
				records = append(records, SegmentEvidence(idx, entry.Value, EvidencePolicy, map[string]any{
					"rule": "canonical_currency", "before": entry.Value, "after": canon,
				}).WithNotes(fmt.Sprintf("currency upcase (%s → %s)", entry.Value, canon)))
			}
			return records
		}
	}

	records = append(records, placeholderDecorationEvidence(entry, segments, idx, c, hints)...)
	return records
}

func placeholderDecorationEvidence(entry SegmentHint, segments []string, idx int, c *SegmentClassifier, hints bool) []Evidence {
	var out []Evidence

	if entry.Type == TypeIPv4 || entry.Type == TypeIPv6 {
		out = append(out, SegmentEvidence(idx, entry.Value, EvidencePolicy, map[string]any{
			"rule": "ip_umbrella_collapse", "from": entry.Type, "to": "ip",
		}).WithNotes(fmt.Sprintf("ip umbrella collapse (%s → ip)", entry.Type)))
	}

	if hints && entry.Hint == "" {
		if _, eligible := hintEligibleTypes[entry.Type]; !eligible {
			if would := wouldBeHint(segments, idx, entry.Type, c); would != "" {
				display := DisplayType(entry.Type)
				out = append(out, SegmentEvidence(idx, entry.Value, EvidenceNeighbor, map[string]any{
					"rule": "hint_suppression", "surfaced": display, "would_be": would,
					"semantic_type": entry.Type,
				}).WithNotes(fmt.Sprintf("semantic type — surfaced as {%s}, not {%s}", display, would)))
			}
		}
	}

	return out
}

func queryParamEvidence(name, value string, c *SegmentClassifier) []Evidence {
	var records []Evidence
	baseType := c.Classify(value)
	effective := baseType

	if hint := ParamNameHint(name, baseType); hint != "" {
		effective = hint
		records = append(records, SegmentEvidence(name, value, EvidenceNeighbor, map[string]any{
			"rule": "param_name_hint", "name": name, "before": baseType, "after": hint,
		}).WithNotes(fmt.Sprintf("param-name hint (`%s=`) lifted %s → %s", name, baseType, hint)))
	}

	records = append(records, SegmentEvidence(name, value, EvidenceRecognizer, map[string]any{
		"type": effective, "variable": c.Variable(effective),
	}))

	switch {
	case effective == TypeDate:
		if canon := CanonicalDate(value); canon != "" && canon != value {
			records = append(records, SegmentEvidence(name, value, EvidencePolicy, map[string]any{
				"rule": "canonical_date", "before": value, "after": canon,
			}).WithNotes(fmt.Sprintf("canonical date (%s → %s)", value, canon)))
		}
	case effective == TypeCurrency:
		if canon := CanonicalCurrency(value); canon != "" && canon != value {
			records = append(records, SegmentEvidence(name, value, EvidencePolicy, map[string]any{
				"rule": "canonical_currency", "before": value, "after": canon,
			}).WithNotes(fmt.Sprintf("currency upcase (%s → %s)", value, canon)))
		}
	case effective == TypeIPv4 || effective == TypeIPv6:
		records = append(records, SegmentEvidence(name, value, EvidencePolicy, map[string]any{
			"rule": "ip_umbrella_collapse", "from": effective, "to": "ip",
		}).WithNotes(fmt.Sprintf("ip umbrella collapse (%s → ip)", effective)))
	}

	return records
}

// ── View rendering (Evidence → TraceRow) ─────────────────────────────

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
		ev := segmentEvidence(e, segments, i, c, hints)
		rows[i] = renderSegmentRow(e, ev, hints)
	}
	return rows
}

func renderSegmentRow(entry SegmentHint, evidence []Evidence, hints bool) TraceRow {
	row := TraceRow{Value: entry.Value, Type: entry.Type, Notes: collectNotes(evidence)}

	if !entry.Variable {
		row.Output = entry.Value
		return row
	}

	if payload := findPolicyPayload(evidence, "canonical_date"); payload != nil {
		row.Output = payload["after"].(string)
		return row
	}
	if payload := findPolicyPayload(evidence, "canonical_currency"); payload != nil {
		row.Output = payload["after"].(string)
		return row
	}

	if hints && entry.Hint != "" {
		row.Output = "{" + entry.Hint + "}"
		return row
	}
	row.Output = "{" + DisplayType(entry.Type) + "}"
	return row
}

func traceQuery(params *OrderedMap, c *SegmentClassifier) []TraceRow {
	keys := params.Keys()
	sortedKeys := append([]string(nil), keys...)
	sort.Strings(sortedKeys)
	rows := make([]TraceRow, 0, len(sortedKeys))
	for _, k := range sortedKeys {
		v, _ := params.Get(k)
		ev := queryParamEvidence(k, v, c)
		rows = append(rows, renderQueryRow(k, v, ev, c))
	}
	return rows
}

func renderQueryRow(name, value string, evidence []Evidence, c *SegmentClassifier) TraceRow {
	notes := collectNotes(evidence)
	effective := findRecognizerType(evidence)
	if effective == "" {
		effective = c.Classify(value)
	}

	output := value
	switch {
	case findPolicyPayload(evidence, "canonical_date") != nil:
		output = findPolicyPayload(evidence, "canonical_date")["after"].(string)
	case findPolicyPayload(evidence, "canonical_currency") != nil:
		output = findPolicyPayload(evidence, "canonical_currency")["after"].(string)
	case c.Variable(effective):
		output = "{" + DisplayType(effective) + "}"
	}

	return TraceRow{Name: name, Value: value, Type: effective, Output: output, Notes: notes}
}

// ── Helpers ──────────────────────────────────────────────────────────

func collectNotes(evidence []Evidence) []string {
	out := []string{}
	for _, e := range evidence {
		out = append(out, e.Notes...)
	}
	return out
}

func findPolicyPayload(evidence []Evidence, rule string) map[string]any {
	for _, e := range evidence {
		if e.Source != EvidencePolicy {
			continue
		}
		if r, _ := e.Payload["rule"].(string); r == rule {
			return e.Payload
		}
	}
	return nil
}

func findRecognizerType(evidence []Evidence) SegmentType {
	for _, e := range evidence {
		if e.Source != EvidenceRecognizer {
			continue
		}
		if t, ok := e.Payload["type"].(SegmentType); ok {
			return t
		}
	}
	return ""
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
