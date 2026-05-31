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
