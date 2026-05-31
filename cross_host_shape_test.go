package iriq

import (
	"fmt"
	"testing"
)

func TestCrossHostShapesEmpty(t *testing.T) {
	cp := NewCorpus()
	cp.Observe("https://foo.com/users/1")
	cp.Observe("https://foo.com/users/2")
	if got := cp.CrossHostShapes(2); len(got) != 0 {
		t.Errorf("single-host corpus should produce no cross-host shapes: got %+v", got)
	}
}

func TestCrossHostShapesAcrossTwoHosts(t *testing.T) {
	cp := NewCorpus()
	cp.Observe("https://foo.com/users/1")
	cp.Observe("https://bar.com/users/2")

	got := cp.CrossHostShapes(2)
	if len(got) != 1 {
		t.Fatalf("got %d shapes, want 1: %+v", len(got), got)
	}
	if got[0].Shape != "/users/{user_id}" {
		t.Errorf("shape = %q", got[0].Shape)
	}
	if got[0].HostCount() != 2 {
		t.Errorf("host count = %d, want 2", got[0].HostCount())
	}
	if got[0].ObservationCount != 2 {
		t.Errorf("obs count = %d, want 2", got[0].ObservationCount)
	}
}

func TestCrossHostShapesHonorsMinHosts(t *testing.T) {
	cp := NewCorpus()
	cp.Observe("https://foo.com/users/1")
	cp.Observe("https://bar.com/users/2")

	if got := cp.CrossHostShapes(2); len(got) != 1 {
		t.Errorf("min=2 should fire: got %+v", got)
	}
	if got := cp.CrossHostShapes(3); len(got) != 0 {
		t.Errorf("min=3 should suppress 2-host signal: got %+v", got)
	}
}

func TestCrossHostShapesRanksByHostCountThenObsThenShape(t *testing.T) {
	cp := NewCorpus()
	for i := 0; i < 3; i++ {
		cp.Observe(fmt.Sprintf("https://h%d.com/users/1", i))
	}
	for i := 0; i < 2; i++ {
		cp.Observe(fmt.Sprintf("https://j%d.com/posts/1", i))
	}
	got := cp.CrossHostShapes(2)
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2", len(got))
	}
	if got[0].Shape != "/users/{user_id}" {
		t.Errorf("rank[0] = %q, want /users/{user_id}", got[0].Shape)
	}
	if got[1].Shape != "/posts/{post_id}" {
		t.Errorf("rank[1] = %q, want /posts/{post_id}", got[1].Shape)
	}
}

func TestCrossHostShapesSkipsURNs(t *testing.T) {
	cp := NewCorpus()
	cp.Observe("urn:isbn:0451450523")
	cp.Observe("urn:isbn:1234567890")
	if got := cp.CrossHostShapes(2); len(got) != 0 {
		t.Errorf("URN clusters should be excluded: got %+v", got)
	}
}
