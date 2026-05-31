package iriq

import "testing"

type fakeRecognizer struct {
	fires       string
	verdictType SegmentType
	specificity float64
}

func (f fakeRecognizer) Try(segment string) (Verdict, bool) {
	if segment != f.fires {
		return Verdict{}, false
	}
	return Verdict{Type: f.verdictType, Confidence: 1.0, Specificity: f.specificity}, true
}

func TestEnsembleNoFire(t *testing.T) {
	high := fakeRecognizer{fires: "match", verdictType: "high", specificity: SpecificitySemantic}
	low := fakeRecognizer{fires: "match", verdictType: "low", specificity: SpecificityTyped}
	if _, ok := Ensemble("nope", high, low); ok {
		t.Errorf("Ensemble should return ok=false when nothing fires")
	}
}

func TestEnsembleSingleFire(t *testing.T) {
	high := fakeRecognizer{fires: "match", verdictType: "high", specificity: SpecificitySemantic}
	never := fakeRecognizer{fires: "different", verdictType: "never", specificity: SpecificitySemantic}
	v, ok := Ensemble("match", high, never)
	if !ok || v.Type != "high" {
		t.Errorf("Ensemble = (%v, %v), want ({high, ...}, true)", v, ok)
	}
}

func TestEnsemblePicksHighestScore(t *testing.T) {
	low := fakeRecognizer{fires: "match", verdictType: "low", specificity: SpecificityTyped}
	high := fakeRecognizer{fires: "match", verdictType: "high", specificity: SpecificitySemantic}
	v, _ := Ensemble("match", low, high)
	if v.Type != "high" {
		t.Errorf("Ensemble picked %v, want high", v.Type)
	}
}

func TestEnsembleTieEarlierWins(t *testing.T) {
	a := fakeRecognizer{fires: "x", verdictType: "a", specificity: 0.5}
	b := fakeRecognizer{fires: "x", verdictType: "b", specificity: 0.5}
	if v, _ := Ensemble("x", a, b); v.Type != "a" {
		t.Errorf("Ensemble(a, b) tie = %v, want a", v.Type)
	}
	if v, _ := Ensemble("x", b, a); v.Type != "b" {
		t.Errorf("Ensemble(b, a) tie = %v, want b", v.Type)
	}
}
