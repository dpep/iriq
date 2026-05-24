package iriq

// Observation is the result of Corpus.Observe.
type Observation struct {
	corpus      *Corpus
	Identifier  *Identifier
	Cluster     *Cluster
	fingerprint string
	explanation []CorpusEntry
}

// Fingerprint returns the deterministic (non-corpus-aware) normalized form.
func (o *Observation) Fingerprint() string {
	if o.fingerprint == "" {
		o.fingerprint = NormalizeIdentifier(o.Identifier, DefaultClassifier, true)
	}
	return o.fingerprint
}

// Explanation returns the corpus-informed explanation. Memoized.
func (o *Observation) Explanation() []CorpusEntry {
	if o.explanation == nil {
		o.explanation = o.corpus.Explain(o.Identifier)
	}
	return o.explanation
}

func (o *Observation) Normalize() string {
	return o.corpus.NormalizeIdentifier(o.Identifier)
}
