package iriq

import "fmt"

// EvidenceSubjectKind distinguishes what an Evidence record is about.
type EvidenceSubjectKind string

const (
	EvidenceSubjectSegment  EvidenceSubjectKind = "segment"
	EvidenceSubjectPosition EvidenceSubjectKind = "position"
	EvidenceSubjectCluster  EvidenceSubjectKind = "cluster"
)

// EvidenceSource distinguishes what kind of fact an Evidence record asserts.
//
//   EvidenceLexical    — pure shape match (e.g. matches a regex)
//   EvidenceRecognizer — a named Recognizer fired with confidence/specificity
//   EvidenceCorpus     — aggregated counts/distributions support this
//   EvidenceNeighbor   — adjacent context informed this (prior literal,
//                        param name hint)
//   EvidencePolicy     — a normalization policy applied (ip umbrella
//                        collapse, canonical date, currency upcase)
type EvidenceSource string

const (
	EvidenceLexical    EvidenceSource = "lexical"
	EvidenceRecognizer EvidenceSource = "recognizer"
	EvidenceCorpus     EvidenceSource = "corpus"
	EvidenceNeighbor   EvidenceSource = "neighbor"
	EvidencePolicy     EvidenceSource = "policy"
)

// Evidence is the structured substrate for explanation.
//
// Each record captures one fact about the system's reasoning: "this segment
// classified as :integer because the Integer recognizer fired", "the IPv4
// type collapses to {ip} by policy", "Position P is mostly variable because
// of corpus stats".
//
// Trace and Explanation are views over Evidence; the structured form is
// what programmatic consumers should build on. Note strings emitted by
// Trace derive from Evidence payloads.
//
//   SubjectKind = segment   Subject is EvidenceSegmentSubject (index + value)
//   SubjectKind = position  Subject is Position
//   SubjectKind = cluster   Subject is the cluster key (string)
//
// Weight is in [0, 1] when meaningful; zero otherwise. Notes are
// human-readable strings — Trace renders them verbatim.
type Evidence struct {
	SubjectKind EvidenceSubjectKind
	Subject     any
	Source      EvidenceSource
	Payload     map[string]any
	Weight      float64
	Notes       []string
}

// EvidenceSegmentSubject identifies a single segment within an Identifier.
// Index is the integer position for path segments and the param name
// (as any) for query params — keeps wire compatibility with Ruby.
type EvidenceSegmentSubject struct {
	Index any    // int for path segments, string for query params
	Value string
}

// SegmentEvidence is a constructor for segment-kind Evidence records.
func SegmentEvidence(index any, value string, source EvidenceSource, payload map[string]any) Evidence {
	return Evidence{
		SubjectKind: EvidenceSubjectSegment,
		Subject:     EvidenceSegmentSubject{Index: index, Value: value},
		Source:      source,
		Payload:     payload,
	}
}

// PositionEvidence is a constructor for position-kind Evidence records.
func PositionEvidence(pos Position, source EvidenceSource, payload map[string]any) Evidence {
	return Evidence{
		SubjectKind: EvidenceSubjectPosition,
		Subject:     pos,
		Source:      source,
		Payload:     payload,
	}
}

// ClusterEvidence is a constructor for cluster-kind Evidence records.
func ClusterEvidence(key string, source EvidenceSource, payload map[string]any) Evidence {
	return Evidence{
		SubjectKind: EvidenceSubjectCluster,
		Subject:     key,
		Source:      source,
		Payload:     payload,
	}
}

// WithNotes returns a copy of the Evidence with the given notes appended.
func (e Evidence) WithNotes(notes ...string) Evidence {
	e.Notes = append(append([]string{}, e.Notes...), notes...)
	return e
}

// WithWeight returns a copy of the Evidence with weight set.
func (e Evidence) WithWeight(w float64) Evidence {
	e.Weight = w
	return e
}

func (e Evidence) String() string {
	return fmt.Sprintf("Evidence(%s/%s, %v)", e.SubjectKind, e.Source, e.Payload)
}
