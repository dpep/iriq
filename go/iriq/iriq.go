// Package iriq is a Go port of the iriq Ruby gem: IRI extraction,
// normalization, and clustering. The public API mirrors the Ruby module's
// module-level helpers (Parse, Normalize, Explain, Extract) plus the
// underlying types (Identifier, Corpus, Clusterer, Extractor, ...).
package iriq

// Extract is a convenience wrapper matching Iriq.extract in Ruby.
func Extract(text string) []*Identifier {
	return NewExtractor().Extract(text)
}
