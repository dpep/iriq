package iriq

import "testing"

func TestEventsForEmitsOrderedSequence(t *testing.T) {
	cp := NewCorpus()
	events, err := cp.EventsFor("https://foo.com/users/123")
	if err != nil {
		t.Fatalf("EventsFor: %v", err)
	}
	if len(events) < 6 {
		t.Fatalf("expected ≥6 events, got %d", len(events))
	}
	if _, ok := events[0].(EventHostSeen); !ok {
		t.Errorf("events[0] = %T, want EventHostSeen", events[0])
	}
	if _, ok := events[len(events)-1].(EventClusterAddition); !ok {
		t.Errorf("events[last] = %T, want EventClusterAddition", events[len(events)-1])
	}

	posCount := 0
	for _, e := range events {
		if _, ok := e.(EventPositionSeen); ok {
			posCount++
		}
	}
	if posCount != 2 {
		t.Errorf("EventPositionSeen count = %d, want 2", posCount)
	}
}

func TestEventsForIsPure(t *testing.T) {
	cp := NewCorpus()
	before := cp.Size()
	_, _ = cp.EventsFor("https://foo.com/users/123")
	if cp.Size() != before {
		t.Errorf("EventsFor mutated corpus: size %d -> %d", before, cp.Size())
	}
}

func TestApplyEventHostSeen(t *testing.T) {
	s := NewMemoryStorage(0)
	ApplyEvent(EventHostSeen{Host: "foo.com"}, s)
	if got := s.HostCounts()["foo.com"]; got != 1 {
		t.Errorf("host_counts['foo.com'] = %d, want 1", got)
	}
}

func TestApplyEventClusterAdditionReturnsCluster(t *testing.T) {
	s := NewMemoryStorage(0)
	iri, _ := Parse("https://foo.com/users/123")
	result := ApplyEvent(EventClusterAddition{
		Key: "k", Host: "foo.com", Scheme: "https", Shape: "/users/{integer}",
		Identifier: iri,
	}, s)
	c, ok := result.(*Cluster)
	if !ok || c == nil {
		t.Fatalf("ApplyEvent(ClusterAddition) = %v, want *Cluster", result)
	}
	if c.Key != "k" {
		t.Errorf("cluster.Key = %q, want %q", c.Key, "k")
	}
}

func TestApplyEventUnknownNoops(t *testing.T) {
	s := NewMemoryStorage(0)
	type bogus struct{}
	// bogus does not implement Event — but we test the contract of
	// ApplyEvent against an Event with an unregistered EventKind.
	type unknown struct{ Event }
	defer func() {
		if r := recover(); r != nil {
			t.Errorf("ApplyEvent panicked on unknown event: %v", r)
		}
	}()
	// Use an EventHostSeen wrapped as an interface but with a manipulated
	// kind via a stub satisfying the Event interface.
	ApplyEvent(stubEvent{kind: "made_up"}, s)
}

type stubEvent struct{ kind string }

func (s stubEvent) EventKind() string { return s.kind }
