package iriq

import (
	"path/filepath"
	"testing"
)

// TestCalibrationCorpus loads spec/fixtures/calibration/segments.json and
// asserts that DefaultClassifier classifies every value as its expected_type.
// Doubles as a regression suite (today's behavior is the ground truth) and
// a target set for the upcoming scored-ensemble step.
func TestCalibrationCorpus(t *testing.T) {
	var fixture struct {
		Segments []struct {
			Value        string `json:"value"`
			ExpectedType string `json:"expected_type"`
			Category     string `json:"category"`
			Source       string `json:"source"`
		} `json:"segments"`
	}
	loadFixture(t, filepath.Join("calibration", "segments.json"), &fixture)

	if len(fixture.Segments) == 0 {
		t.Fatal("calibration fixture is empty — run script/build_calibration.rb")
	}

	for _, s := range fixture.Segments {
		t.Run(s.Value, func(t *testing.T) {
			got := DefaultClassifier.Classify(s.Value)
			if string(got) != s.ExpectedType {
				t.Errorf("classify(%q) = %s, want %s (%s: %s)",
					s.Value, got, s.ExpectedType, s.Category, s.Source)
			}
		})
	}
}
