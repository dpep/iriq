package iriq

// Recognizer is a pluggable single-type classifier.
//
// Try returns a Verdict and ok=true when the Recognizer claims the segment;
// otherwise ok=false. The ensemble-based SegmentClassifier consults
// Recognizers in order and picks the first that fires. (Scored-ensemble
// voting comes in a follow-up; for now each fire is decisive.)
//
// Confidence is in [0, 1]. Phase-1 step 2 always returns 1.0 when a
// Recognizer fires; calibration arrives with the scored ensemble in step 4.
//
// Canonical is the canonical form (e.g. ISO date for TypeDate); empty
// means "use the input as-is".
type Recognizer interface {
	Try(segment string) (Verdict, bool)
}

// Verdict is the structured result returned by a Recognizer.
//
// Confidence × Specificity is the score used by Ensemble to pick the
// winning Verdict when multiple Recognizers fire on the same segment.
type Verdict struct {
	Type        SegmentType
	Confidence  float64
	Specificity float64
	Canonical   string
	Notes       []string
}

// Ensemble runs each Recognizer against the segment and returns the
// winning Verdict — the one with max(specificity × confidence). Ties go
// to the earlier Recognizer in the slice (stable, deterministic).
// Returns ok=false when no Recognizer fires.
//
// Stepping-stone toward the full scored ensemble: today only three
// Recognizers participate (uuid, date, integer) and they're
// mutually-exclusive on shape, so the ensemble's max-specificity
// tie-break never actually fires — but the seam is in place for
// follow-up commits that carve more Recognizers out and let scoring
// decide.
func Ensemble(segment string, recognizers ...Recognizer) (Verdict, bool) {
	var best Verdict
	bestScore := -1.0
	found := false
	for _, r := range recognizers {
		v, ok := r.Try(segment)
		if !ok {
			continue
		}
		score := v.Specificity * v.Confidence
		if score > bestScore {
			best = v
			bestScore = score
			found = true
		}
	}
	return best, found
}
