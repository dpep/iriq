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
type Verdict struct {
	Type       SegmentType
	Confidence float64
	Canonical  string
	Notes      []string
}
