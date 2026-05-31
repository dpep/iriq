package iriq

import "testing"

func TestSegmentEvidence(t *testing.T) {
	e := SegmentEvidence(0, "users", EvidenceRecognizer, map[string]any{
		"type": "literal",
	})
	if e.SubjectKind != EvidenceSubjectSegment {
		t.Errorf("SubjectKind = %s, want segment", e.SubjectKind)
	}
	sub, ok := e.Subject.(EvidenceSegmentSubject)
	if !ok {
		t.Fatalf("Subject = %T, want EvidenceSegmentSubject", e.Subject)
	}
	if sub.Index != 0 || sub.Value != "users" {
		t.Errorf("Subject = %+v", sub)
	}
}

func TestPositionEvidence(t *testing.T) {
	pos := PathPosition("foo.com", "/users")
	e := PositionEvidence(pos, EvidenceCorpus, map[string]any{"observations": 42})
	if e.SubjectKind != EvidenceSubjectPosition {
		t.Errorf("SubjectKind = %s", e.SubjectKind)
	}
	if got, _ := e.Subject.(Position); got != pos {
		t.Errorf("Subject = %v, want %v", got, pos)
	}
}

func TestClusterEvidence(t *testing.T) {
	e := ClusterEvidence("https://foo.com/users/{integer}", EvidenceCorpus, map[string]any{"count": 10})
	if e.SubjectKind != EvidenceSubjectCluster {
		t.Errorf("SubjectKind = %s", e.SubjectKind)
	}
	if got := e.Subject.(string); got != "https://foo.com/users/{integer}" {
		t.Errorf("Subject = %q", got)
	}
}

func TestEvidenceWithNotes(t *testing.T) {
	e := SegmentEvidence(0, "x", EvidencePolicy, nil).WithNotes("hello", "world")
	if len(e.Notes) != 2 || e.Notes[0] != "hello" || e.Notes[1] != "world" {
		t.Errorf("Notes = %v", e.Notes)
	}
}

func TestEvidenceForEmitsRecognizerPerSegment(t *testing.T) {
	ev, err := EvidenceFor("https://foo.com/users/123")
	if err != nil {
		t.Fatalf("EvidenceFor: %v", err)
	}
	var recogTypes []SegmentType
	for _, r := range ev {
		if r.Source == EvidenceRecognizer {
			if t, ok := r.Payload["type"].(SegmentType); ok {
				recogTypes = append(recogTypes, t)
			}
		}
	}
	if len(recogTypes) != 2 || recogTypes[0] != TypeLiteral || recogTypes[1] != TypeInteger {
		t.Errorf("recognizer types = %v, want [literal integer]", recogTypes)
	}
}

func TestEvidenceForCanonicalDate(t *testing.T) {
	ev, err := EvidenceFor("https://foo.com/c?d=2024/01/15")
	if err != nil {
		t.Fatalf("EvidenceFor: %v", err)
	}
	var found *Evidence
	for i := range ev {
		if ev[i].Source == EvidencePolicy {
			if r, _ := ev[i].Payload["rule"].(string); r == "canonical_date" {
				found = &ev[i]
				break
			}
		}
	}
	if found == nil {
		t.Fatalf("no canonical_date policy Evidence in %v", ev)
	}
	if got, _ := found.Payload["after"].(string); got != "2024-01-15" {
		t.Errorf("canonical_date after = %q, want 2024-01-15", got)
	}
}

func TestEvidenceForParamNameHint(t *testing.T) {
	ev, err := EvidenceFor("https://foo.com/c?phone=unknown")
	if err != nil {
		t.Fatalf("EvidenceFor: %v", err)
	}
	var hint *Evidence
	for i := range ev {
		if ev[i].Source == EvidenceNeighbor {
			if r, _ := ev[i].Payload["rule"].(string); r == "param_name_hint" {
				hint = &ev[i]
				break
			}
		}
	}
	if hint == nil {
		t.Fatalf("no param_name_hint Evidence")
	}
	if got, _ := hint.Payload["after"].(SegmentType); got != TypePhone {
		t.Errorf("after = %v, want phone", got)
	}
}

func TestTraceForNotesEqualEvidenceForNotes(t *testing.T) {
	input := "https://shop.com/pricing/usd?currency=eur"
	view, err := Trace(input)
	if err != nil {
		t.Fatalf("Trace: %v", err)
	}
	ev, err := EvidenceFor(input)
	if err != nil {
		t.Fatalf("EvidenceFor: %v", err)
	}
	var viewNotes, evNotes []string
	for _, r := range view.Path {
		viewNotes = append(viewNotes, r.Notes...)
	}
	for _, r := range view.Query {
		viewNotes = append(viewNotes, r.Notes...)
	}
	for _, e := range ev {
		evNotes = append(evNotes, e.Notes...)
	}
	if len(viewNotes) != len(evNotes) {
		t.Errorf("view notes count %d != ev notes count %d\nview: %v\nev: %v",
			len(viewNotes), len(evNotes), viewNotes, evNotes)
	}
}
