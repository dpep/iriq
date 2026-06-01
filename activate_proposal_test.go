package iriq

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func observePATs(t *testing.T, cp *Corpus, n int, host string) {
	t.Helper()
	for i := 0; i < n; i++ {
		if _, err := cp.Observe(fmt.Sprintf("https://%s/auth/ghp_aaaa%04dxyzzy", host, i)); err != nil {
			t.Fatalf("Observe: %v", err)
		}
	}
}

func TestActivateProposalRegistersOnPerCorpusClassifier(t *testing.T) {
	cp := NewCorpus()
	observePATs(t, cp, 25, "api.github.com")
	proposals := cp.ProposeRecognizers(nil, ProposalOptions{})
	if len(proposals) == 0 {
		t.Fatal("no proposals to activate")
	}
	r, err := cp.ActivateProposal(proposals[0])
	if err != nil {
		t.Fatalf("ActivateProposal: %v", err)
	}
	if r.Prefix != "ghp_" {
		t.Errorf("prefix = %q, want ghp_", r.Prefix)
	}
	if cp.Classifier == DefaultClassifier {
		t.Errorf("ActivateProposal should switch off DefaultClassifier")
	}
}

func TestActivateProposalDoesntLeakIntoDefault(t *testing.T) {
	cp := NewCorpus()
	observePATs(t, cp, 25, "api.github.com")
	proposals := cp.ProposeRecognizers(nil, ProposalOptions{})
	_, _ = cp.ActivateProposal(proposals[0])

	other := NewCorpus()
	// DefaultClassifier should still be the 3 built-ins; no SynthesizedRecognizer.
	for _, r := range other.Classifier.Recognizers() {
		if _, ok := r.(*SynthesizedRecognizer); ok {
			t.Errorf("DefaultClassifier leaked SynthesizedRecognizer")
		}
	}
}

func TestActivateProposalReclassifiesMatchingValues(t *testing.T) {
	cp := NewCorpus()
	observePATs(t, cp, 25, "api.github.com")
	_, _ = cp.ActivateProposal(cp.ProposeRecognizers(nil, ProposalOptions{})[0])

	got := cp.Classifier.Classify("ghp_abcdef123")
	if got != SegmentType("ghp") {
		t.Errorf("Classify after activation = %s, want ghp", got)
	}
}

func TestActivateProposalReinfersExistingObservations(t *testing.T) {
	cp := NewCorpus()
	observePATs(t, cp, 25, "api.github.com")

	stats := cp.StatsFor("api.github.com", "/auth")
	if _, has := stats.TypeCounts["ghp"]; has {
		t.Fatal("type_counts should not contain :ghp before activation")
	}

	_, _ = cp.ActivateProposal(cp.ProposeRecognizers(nil, ProposalOptions{})[0])

	stats = cp.StatsFor("api.github.com", "/auth")
	if cnt, has := stats.TypeCounts["ghp"]; !has || cnt == 0 {
		t.Errorf("type_counts should contain :ghp after activation: %+v", stats.TypeCounts)
	}
}

func TestActivateProposalPersistsAcrossSQLiteReopens(t *testing.T) {
	if !HasSqlite {
		t.Skip("requires build tag: sqlite")
	}
	dir, err := os.MkdirTemp("", "iriq-activate")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "corpus.db")

	c1, err := OpenCorpus(path)
	if err != nil {
		t.Fatalf("OpenCorpus: %v", err)
	}
	observePATs(t, c1, 25, "api.github.com")
	if _, err := c1.ActivateProposal(c1.ProposeRecognizers(nil, ProposalOptions{})[0]); err != nil {
		t.Fatalf("ActivateProposal: %v", err)
	}
	_ = c1.Close()

	c2, err := OpenCorpus(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer c2.Close()
	if got := c2.ActivatedRecognizerCount(); got != 1 {
		t.Errorf("ActivatedRecognizerCount after reopen = %d, want 1", got)
	}
	if got := c2.Classifier.Classify("ghp_xyzzy123"); got != SegmentType("ghp") {
		t.Errorf("Classify after reopen = %s, want ghp", got)
	}
}

func TestActivateProposalsAboveThreshold(t *testing.T) {
	cp := NewCorpus()
	observePATs(t, cp, 25, "api.github.com")
	activated, err := cp.ActivateProposalsAbove(0.5, ProposalOptions{})
	if err != nil {
		t.Fatalf("ActivateProposalsAbove: %v", err)
	}
	if len(activated) != 1 || activated[0].Prefix != "ghp_" {
		t.Errorf("activated = %+v", activated)
	}

	cp2 := NewCorpus()
	observePATs(t, cp2, 25, "api.github.com")
	if a, _ := cp2.ActivateProposalsAbove(1.5, ProposalOptions{}); len(a) != 0 {
		t.Errorf("threshold 1.5 should activate nothing: got %d", len(a))
	}
}
