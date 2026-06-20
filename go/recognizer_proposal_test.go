package iriq

import (
	"fmt"
	"testing"
)

func TestProposeRecognizersEmptyCorpus(t *testing.T) {
	cp := NewCorpus()
	if got := cp.ProposeRecognizers(nil, ProposalOptions{}); len(got) != 0 {
		t.Errorf("ProposeRecognizers on empty = %v, want empty", got)
	}
}

func TestProposeRecognizersGitHubPAT(t *testing.T) {
	cp := NewCorpus()
	for i := 0; i < 25; i++ {
		if _, err := cp.Observe(fmt.Sprintf("https://api.github.com/auth/ghp_aaaa%04dxyzzy", i)); err != nil {
			t.Fatalf("Observe: %v", err)
		}
	}
	proposals := cp.ProposeRecognizers(nil, ProposalOptions{})
	if len(proposals) != 1 {
		t.Fatalf("proposals = %d, want 1: %+v", len(proposals), proposals)
	}
	p := proposals[0]
	if p.Prefix != "ghp_" {
		t.Errorf("Prefix = %q, want ghp_", p.Prefix)
	}
	if p.SuggestedType != "ghp" {
		t.Errorf("SuggestedType = %q, want ghp", p.SuggestedType)
	}
	if p.Coverage < 0.99 {
		t.Errorf("Coverage = %f, want ~1.0", p.Coverage)
	}
	if p.ObservationCount != 25 {
		t.Errorf("ObservationCount = %d, want 25", p.ObservationCount)
	}
	if p.Strategy != "prefix_underscore_id" {
		t.Errorf("Strategy = %q", p.Strategy)
	}
}

func TestProposeRecognizersBelowNoiseFloor(t *testing.T) {
	cp := NewCorpus()
	for i := 0; i < 10; i++ {
		_, _ = cp.Observe(fmt.Sprintf("https://api.github.com/auth/ghp_ab%04dcdwxyz", i))
	}
	if got := cp.ProposeRecognizers(nil, ProposalOptions{}); len(got) != 0 {
		t.Errorf("ProposeRecognizers below floor = %v, want empty", got)
	}
}

func TestProposeRecognizersCoverageFloor(t *testing.T) {
	cp := NewCorpus()
	for i := 0; i < 5; i++ {
		_, _ = cp.Observe(fmt.Sprintf("https://foo.com/x/ghp_abcd%defghijklmn", i))
	}
	for i := 0; i < 25; i++ {
		_, _ = cp.Observe(fmt.Sprintf("https://foo.com/x/red-team-member-%d", i))
	}
	if got := cp.ProposeRecognizers(nil, ProposalOptions{}); len(got) != 0 {
		t.Errorf("coverage below floor should suppress proposal: got %+v", got)
	}
}

func TestProposeRecognizersMinHosts(t *testing.T) {
	cp := NewCorpus()
	for i := 0; i < 25; i++ {
		_, _ = cp.Observe(fmt.Sprintf("https://api.github.com/auth/ghp_abcd%04dwxyz", i))
	}
	if got := cp.ProposeRecognizers(nil, ProposalOptions{MinHosts: 1}); len(got) != 1 {
		t.Errorf("MinHosts=1 should fire: got %d proposals", len(got))
	}
	if got := cp.ProposeRecognizers(nil, ProposalOptions{MinHosts: 2}); len(got) != 0 {
		t.Errorf("MinHosts=2 should suppress single-host signal: got %+v", got)
	}
}

func TestProposeRecognizersEmptyStrategiesDisablesAll(t *testing.T) {
	cp := NewCorpus()
	for i := 0; i < 25; i++ {
		_, _ = cp.Observe(fmt.Sprintf("https://api.github.com/auth/ghp_ab%04dcdwxyz", i))
	}
	if got := cp.ProposeRecognizers([]ProposalStrategy{}, ProposalOptions{}); len(got) != 0 {
		t.Errorf("empty strategies should produce 0 proposals: got %+v", got)
	}
}
