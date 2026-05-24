package iriq

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strconv"
	"testing"
)

// fixturesDir locates spec/fixtures/ from this Go test file. The Go package
// lives at the repo root, so the fixtures dir is a direct sibling.
func fixturesDir(t *testing.T) string {
	t.Helper()
	_, here, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	return filepath.Join(filepath.Dir(here), "spec", "fixtures")
}

func loadFixture(t *testing.T, name string, v interface{}) {
	t.Helper()
	path := filepath.Join(fixturesDir(t), name)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v (run `bundle exec ruby script/generate_fixtures.rb`)", path, err)
	}
	if err := json.Unmarshal(data, v); err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}
}

type parserCase struct {
	Input      string `json:"input"`
	Identifier struct {
		Original     string            `json:"original"`
		Kind         string            `json:"kind"`
		Scheme       *string           `json:"scheme"`
		Host         *string           `json:"host"`
		Port         *int              `json:"port"`
		PathSegments []string          `json:"path_segments"`
		QueryParams  map[string]string `json:"query_params"`
		Fragment     *string           `json:"fragment"`
		NSS          *string           `json:"nss"`
		Canonical    string            `json:"canonical"`
	} `json:"identifier"`
}

func TestFixtureParser(t *testing.T) {
	var fx struct {
		Cases []parserCase `json:"cases"`
	}
	loadFixture(t, "parser.json", &fx)

	for _, c := range fx.Cases {
		iri, err := Parse(c.Input)
		if err != nil {
			t.Errorf("Parse(%q): %v", c.Input, err)
			continue
		}
		want := c.Identifier
		if iri.Original != want.Original {
			t.Errorf("%q: original %q != %q", c.Input, iri.Original, want.Original)
		}
		if iri.Kind.String() != want.Kind {
			t.Errorf("%q: kind %q != %q", c.Input, iri.Kind.String(), want.Kind)
		}
		if !strPtrEq(strOrNil(iri.Scheme), want.Scheme) {
			t.Errorf("%q: scheme mismatch", c.Input)
		}
		if !strPtrEq(strOrNil(iri.Host), want.Host) {
			t.Errorf("%q: host mismatch", c.Input)
		}
		if !intPtrEq(intOrNil(iri.Port), want.Port) {
			t.Errorf("%q: port mismatch (%v vs %v)", c.Input, iri.Port, want.Port)
		}
		// Treat nil and empty slice as equivalent — JSON encodes both.
		gotSegs := iri.PathSegments
		if gotSegs == nil {
			gotSegs = []string{}
		}
		wantSegs := want.PathSegments
		if wantSegs == nil {
			wantSegs = []string{}
		}
		if !reflect.DeepEqual(gotSegs, wantSegs) {
			t.Errorf("%q: path_segments %#v != %#v", c.Input, gotSegs, wantSegs)
		}
		if !reflect.DeepEqual(iri.QueryParams.ToMap(), want.QueryParams) && !(iri.QueryParams.Len() == 0 && len(want.QueryParams) == 0) {
			t.Errorf("%q: query_params %#v != %#v", c.Input, iri.QueryParams.ToMap(), want.QueryParams)
		}
		if !strPtrEq(strOrNil(iri.Fragment), want.Fragment) {
			t.Errorf("%q: fragment mismatch", c.Input)
		}
		if !strPtrEq(strOrNil(iri.NSS), want.NSS) {
			t.Errorf("%q: nss mismatch", c.Input)
		}
		if iri.Canonical() != want.Canonical {
			t.Errorf("%q: canonical %q != %q", c.Input, iri.Canonical(), want.Canonical)
		}
	}
}

func strOrNil(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func intOrNil(n int) *int {
	if n == 0 {
		return nil
	}
	return &n
}

func strPtrEq(a, b *string) bool {
	if a == nil && b == nil {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	return *a == *b
}

func intPtrEq(a, b *int) bool {
	if a == nil && b == nil {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	return *a == *b
}

func TestFixtureClassifier(t *testing.T) {
	var fx struct {
		Cases []struct {
			Input string `json:"input"`
			Type  string `json:"type"`
		} `json:"cases"`
	}
	loadFixture(t, "classifier.json", &fx)
	c := NewSegmentClassifier()
	for _, k := range fx.Cases {
		if got := string(c.Classify(k.Input)); got != k.Type {
			t.Errorf("Classify(%q) = %q, want %q", k.Input, got, k.Type)
		}
	}
}

func TestFixtureInflector(t *testing.T) {
	var fx struct {
		Cases []struct {
			Input    string `json:"input"`
			Singular string `json:"singular"`
		} `json:"cases"`
	}
	loadFixture(t, "inflector.json", &fx)
	for _, c := range fx.Cases {
		if got := Singularize(c.Input); got != c.Singular {
			t.Errorf("Singularize(%q) = %q, want %q", c.Input, got, c.Singular)
		}
	}
}

func TestFixtureNormalizer(t *testing.T) {
	var fx struct {
		Cases []struct {
			Input  string `json:"input"`
			Hints  bool   `json:"hints"`
			Output string `json:"output"`
		} `json:"cases"`
	}
	loadFixture(t, "normalizer.json", &fx)
	for _, c := range fx.Cases {
		got, err := NormalizeWith(c.Input, DefaultClassifier, c.Hints)
		if err != nil {
			t.Errorf("Normalize(%q, hints=%v): %v", c.Input, c.Hints, err)
			continue
		}
		if got != c.Output {
			t.Errorf("Normalize(%q, hints=%v) = %q, want %q", c.Input, c.Hints, got, c.Output)
		}
	}
}

func TestFixturePathShape(t *testing.T) {
	var fx struct {
		Cases []struct {
			Segments []string `json:"segments"`
			Hints    bool     `json:"hints"`
			Shape    string   `json:"shape"`
		} `json:"cases"`
	}
	loadFixture(t, "pathshape.json", &fx)
	for _, c := range fx.Cases {
		if got := PathShapeFor(c.Segments, c.Hints); got != c.Shape {
			t.Errorf("PathShapeFor(%v, hints=%v) = %q, want %q", c.Segments, c.Hints, got, c.Shape)
		}
	}
}

func TestFixtureExplanation(t *testing.T) {
	var fx struct {
		Cases []struct {
			Input   string `json:"input"`
			Entries []struct {
				Value    string  `json:"value"`
				Type     string  `json:"type"`
				Variable bool    `json:"variable"`
				Hint     *string `json:"hint"`
			} `json:"entries"`
		} `json:"cases"`
	}
	loadFixture(t, "explanation.json", &fx)
	for _, c := range fx.Cases {
		entries, err := Explain(c.Input)
		if err != nil {
			t.Errorf("Explain(%q): %v", c.Input, err)
			continue
		}
		if len(entries) != len(c.Entries) {
			t.Errorf("Explain(%q): len = %d, want %d", c.Input, len(entries), len(c.Entries))
			continue
		}
		for i, e := range c.Entries {
			got := entries[i]
			gotHint := ""
			if e.Hint != nil {
				gotHint = *e.Hint
			}
			if got.Value != e.Value || string(got.Type) != e.Type || got.Variable != e.Variable || got.Hint != gotHint {
				t.Errorf("Explain(%q)[%d] = %+v, want value=%q type=%q variable=%v hint=%q",
					c.Input, i, got, e.Value, e.Type, e.Variable, gotHint)
			}
		}
	}
}

func TestFixtureExtractor(t *testing.T) {
	var fx struct {
		Cases []struct {
			Text      string   `json:"text"`
			Extracted []string `json:"extracted"`
			Strict    []string `json:"strict"`
		} `json:"cases"`
	}
	loadFixture(t, "extractor.json", &fx)
	defaultExt := NewExtractor()
	strictExt := &Extractor{SchemeLess: false}
	for _, c := range fx.Cases {
		got := defaultExt.ExtractStrings(c.Text)
		want := c.Extracted
		if !sliceEq(got, want) {
			t.Errorf("Extract(%q) = %v, want %v", c.Text, got, want)
		}
		gotStrict := strictExt.ExtractStrings(c.Text)
		if !sliceEq(gotStrict, c.Strict) {
			t.Errorf("Extract(%q, strict) = %v, want %v", c.Text, gotStrict, c.Strict)
		}
	}
}

func sliceEq(a, b []string) bool {
	if len(a) == 0 && len(b) == 0 {
		return true
	}
	return reflect.DeepEqual(a, b)
}

func TestFixtureCorpusStream(t *testing.T) {
	var fx struct {
		Seed     int      `json:"seed"`
		Count    int      `json:"count"`
		Inputs   []string `json:"inputs"`
		Expected struct {
			HostCounts        map[string]int `json:"host_counts"`
			PathLengthCounts  map[string]int `json:"path_length_counts"`
			RawShapeCounts    map[string]int `json:"raw_shape_counts"`
			FingerprintCounts map[string]int `json:"fingerprint_counts"`
			ClusterCount      int            `json:"cluster_count"`
		} `json:"expected"`
	}
	loadFixture(t, "corpus_stream.json", &fx)

	c := NewCorpus()
	for _, u := range fx.Inputs {
		if _, err := c.Observe(u); err != nil {
			t.Fatalf("Observe(%q): %v", u, err)
		}
	}
	if !reflect.DeepEqual(c.HostCounts, fx.Expected.HostCounts) {
		t.Errorf("host_counts mismatch:\n  go:   %v\n  want: %v", c.HostCounts, fx.Expected.HostCounts)
	}
	for k, v := range fx.Expected.PathLengthCounts {
		n, err := strconv.Atoi(k)
		if err != nil {
			t.Fatalf("non-integer path_length_counts key %q: %v", k, err)
		}
		if c.PathLengthCounts[n] != v {
			t.Errorf("path_length_counts[%d] = %d, want %d", n, c.PathLengthCounts[n], v)
		}
	}
	if !reflect.DeepEqual(c.RawShapeCounts, fx.Expected.RawShapeCounts) {
		t.Errorf("raw_shape_counts mismatch")
	}
	if !reflect.DeepEqual(c.FingerprintCounts, fx.Expected.FingerprintCounts) {
		t.Errorf("fingerprint_counts mismatch")
	}
	if c.Size() != fx.Expected.ClusterCount {
		t.Errorf("cluster count = %d, want %d", c.Size(), fx.Expected.ClusterCount)
	}
}

func TestFixtureCorpusDump(t *testing.T) {
	// Load the Ruby-produced corpus dump, then verify Go reads it correctly
	// and a re-observe produces a consistent host_counts.
	path := filepath.Join(fixturesDir(t), "corpus_dump.json")
	c, err := LoadCorpus(path)
	if err != nil {
		t.Fatalf("LoadCorpus: %v", err)
	}
	if c.HostCounts["foo.com"] != 4 || c.HostCounts["bar.com"] != 1 {
		t.Errorf("host_counts = %v", c.HostCounts)
	}
	if c.Size() == 0 {
		t.Errorf("expected clusters")
	}
	// Round-trip: save with Go, load again, verify identical aggregates.
	dir := t.TempDir()
	out := filepath.Join(dir, "out.json")
	if err := c.Save(out); err != nil {
		t.Fatal(err)
	}
	reloaded, err := LoadCorpus(out)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(reloaded.HostCounts, c.HostCounts) {
		t.Errorf("round-trip host_counts mismatch")
	}
	if !reflect.DeepEqual(reloaded.RawShapeCounts, c.RawShapeCounts) {
		t.Errorf("round-trip raw_shape_counts mismatch")
	}
}
