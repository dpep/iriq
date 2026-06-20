package iriq

import "testing"

func TestObservedIRICount(t *testing.T) {
	cp := NewCorpus()
	if got := cp.ObservedIRICount(); got != 0 {
		t.Errorf("initial ObservedIRICount = %d, want 0", got)
	}
	_, _ = cp.Observe("https://foo.com/users/1")
	_, _ = cp.Observe("https://foo.com/users/2")
	if got := cp.ObservedIRICount(); got != 2 {
		t.Errorf("ObservedIRICount = %d, want 2", got)
	}
}

func TestReinferRebuildsViews(t *testing.T) {
	cp := NewCorpus()
	for _, u := range []string{
		"https://foo.com/users/1",
		"https://foo.com/users/2",
		"https://foo.com/users/3",
	} {
		if _, err := cp.Observe(u); err != nil {
			t.Fatalf("Observe %q: %v", u, err)
		}
	}

	originalSize := cp.Size()
	originalHosts := cp.HostCounts()["foo.com"]

	if err := cp.Reinfer(); err != nil {
		t.Fatalf("Reinfer: %v", err)
	}

	if got := cp.Size(); got != originalSize {
		t.Errorf("Size after Reinfer = %d, want %d", got, originalSize)
	}
	if got := cp.HostCounts()["foo.com"]; got != originalHosts {
		t.Errorf("host_counts[foo.com] after Reinfer = %d, want %d", got, originalHosts)
	}
	if got := cp.ObservedIRICount(); got != 3 {
		t.Errorf("ObservedIRICount after Reinfer = %d, want 3", got)
	}
}

func TestReinferIdempotent(t *testing.T) {
	cp := NewCorpus()
	_, _ = cp.Observe("https://foo.com/users/1")
	_, _ = cp.Observe("https://foo.com/users/2")

	if err := cp.Reinfer(); err != nil {
		t.Fatalf("Reinfer #1: %v", err)
	}
	first := cp.HostCounts()["foo.com"]
	if err := cp.Reinfer(); err != nil {
		t.Fatalf("Reinfer #2: %v", err)
	}
	if got := cp.HostCounts()["foo.com"]; got != first {
		t.Errorf("Reinfer not idempotent: %d -> %d", first, got)
	}
}
