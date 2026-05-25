package iriq

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestCorpusObserve(t *testing.T) {
	c := NewCorpus()
	obs, err := c.Observe("https://foo.com/users/123")
	if err != nil {
		t.Fatal(err)
	}
	if obs.Fingerprint() != "https://foo.com/users/{user_id}" {
		t.Errorf("fingerprint = %q", obs.Fingerprint())
	}
	if obs.Cluster == nil {
		t.Error("cluster nil")
	}
	exp := obs.Explanation()
	last := exp[len(exp)-1]
	if last.Value != "123" || last.Type != TypeIntegerID {
		t.Errorf("last = %#v", last)
	}
}

func TestCorpusAggregates(t *testing.T) {
	c := NewCorpus()
	for _, in := range []string{
		"https://foo.com/users/1",
		"https://foo.com/users/2",
		"https://foo.com/posts/abc-123",
		"https://bar.com/x",
	} {
		_, _ = c.Observe(in)
	}
	if !reflect.DeepEqual(c.HostCounts(), map[string]int{"foo.com": 3, "bar.com": 1}) {
		t.Errorf("host_counts = %#v", c.HostCounts())
	}
	if !reflect.DeepEqual(c.PathLengthCounts(), map[int]int{2: 3, 1: 1}) {
		t.Errorf("path_length_counts = %#v", c.PathLengthCounts())
	}
	if got := c.RawShapeCounts()["/users/{integer_id}"]; got != 2 {
		t.Errorf("/users/{integer_id} = %d", got)
	}
	if got := c.FingerprintCounts()["/users/{user_id}"]; got != 2 {
		t.Errorf("/users/{user_id} = %d", got)
	}
}

func TestCorpusPositionStats(t *testing.T) {
	c := NewCorpus()
	for _, in := range []string{
		"https://foo.com/users/123",
		"https://foo.com/users/456",
		"https://foo.com/users/me",
	} {
		_, _ = c.Observe(in)
	}
	stats := c.StatsFor("foo.com", "/users")
	if stats.Total != 3 {
		t.Errorf("total = %d", stats.Total)
	}
	want := map[string]int{"123": 1, "456": 1, "me": 1}
	if !reflect.DeepEqual(stats.ValueCounts, want) {
		t.Errorf("value_counts = %#v", stats.ValueCounts)
	}
	if stats.TypeCounts[TypeIntegerID] != 2 || stats.TypeCounts[TypeLiteral] != 1 {
		t.Errorf("type_counts = %#v", stats.TypeCounts)
	}
}

func TestCorpusInferredVariable(t *testing.T) {
	c := NewCorpus()
	names := []string{"alice", "bob", "carol", "dave", "erin", "frank", "gina", "hank", "ivan", "jane"}
	for _, n := range names {
		_, _ = c.Observe("https://foo.com/users/" + n + "/profile")
	}
	exp := c.Explain("https://foo.com/users/alice/profile")
	if exp[1].Classification != ClassCorpusInferredVariable {
		t.Errorf("[1].classification = %q", exp[1].Classification)
	}
	if exp[0].Classification != ClassStableLiteral || exp[2].Classification != ClassStableLiteral {
		t.Errorf("stable positions wrong: %v %v", exp[0].Classification, exp[2].Classification)
	}
	got, _ := c.Normalize("https://foo.com/users/alice/profile")
	if got != "https://foo.com/users/{user}/profile" {
		t.Errorf("normalize = %q", got)
	}
}

func TestCorpusStableLiteralDominates(t *testing.T) {
	c := NewCorpus()
	for i := 0; i < 9; i++ {
		_, _ = c.Observe("https://foo.com/users/me")
	}
	_, _ = c.Observe("https://foo.com/users/123")
	exp := c.Explain("https://foo.com/users/me")
	if exp[1].Classification != ClassStableLiteral {
		t.Errorf("classification = %q", exp[1].Classification)
	}
}

func TestCorpusRareLiteralOutlier(t *testing.T) {
	c := NewCorpus()
	for i := 0; i < 6; i++ {
		_, _ = c.Observe("https://foo.com/users/" + itoa(i))
	}
	_, _ = c.Observe("https://foo.com/users/me")
	exp := c.Explain("https://foo.com/users/me")
	if exp[1].Classification != ClassRareLiteral {
		t.Errorf("classification = %q", exp[1].Classification)
	}
}

func TestCorpusAmbiguousNeverSeen(t *testing.T) {
	c := NewCorpus()
	for i := 0; i < 6; i++ {
		_, _ = c.Observe("https://foo.com/users/" + itoa(i))
	}
	exp := c.Explain("https://foo.com/users/unseen")
	if exp[1].Classification != ClassAmbiguous {
		t.Errorf("classification = %q", exp[1].Classification)
	}
}

func TestCorpusMemoryCaps(t *testing.T) {
	c := NewCorpusWith(nil, 5)
	for i := 0; i < 20; i++ {
		_, _ = c.Observe("https://foo.com/items/" + itoa(i))
	}
	stats := c.StatsFor("foo.com", "/items")
	if stats.Cardinality() != 5 {
		t.Errorf("cardinality = %d, want 5", stats.Cardinality())
	}
	if stats.Total != 20 {
		t.Errorf("total = %d", stats.Total)
	}
}

func TestCorpusClusterExamplesCap(t *testing.T) {
	c := NewCorpus()
	for i := 0; i < 30; i++ {
		_, _ = c.Observe("https://foo.com/users/" + itoa(i))
	}
	cl := c.Clusters()[0]
	if cl.Count != 30 {
		t.Errorf("count = %d", cl.Count)
	}
	if len(cl.Examples) != MaxClusterExamples {
		t.Errorf("examples = %d, want %d", len(cl.Examples), MaxClusterExamples)
	}
}

func TestCorpusURN(t *testing.T) {
	c := NewCorpus()
	obs, _ := c.Observe("urn:isbn:0451450523")
	if obs.Fingerprint() != "urn:isbn:{isbn_id}" {
		t.Errorf("fingerprint = %q", obs.Fingerprint())
	}
	got, _ := c.Normalize("urn:isbn:0451450523")
	if got != "urn:isbn:{isbn_id}" {
		t.Errorf("normalize = %q", got)
	}
}

func TestCorpusSaveLoad(t *testing.T) {
	c := NewCorpus()
	for _, in := range []string{
		"https://foo.com/users/1",
		"https://foo.com/users/2",
		"https://foo.com/posts/abc-123",
	} {
		_, _ = c.Observe(in)
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "corpus.json")
	if err := c.Save(path); err != nil {
		t.Fatal(err)
	}
	restored, err := LoadCorpus(path)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(restored.HostCounts(), c.HostCounts()) {
		t.Errorf("host_counts mismatch: %#v vs %#v", restored.HostCounts(), c.HostCounts())
	}
	if !reflect.DeepEqual(restored.RawShapeCounts(), c.RawShapeCounts()) {
		t.Errorf("raw_shape_counts mismatch")
	}
	if !reflect.DeepEqual(restored.FingerprintCounts(), c.FingerprintCounts()) {
		t.Errorf("fingerprint_counts mismatch")
	}
	if restored.Size() != c.Size() {
		t.Errorf("size mismatch: %d vs %d", restored.Size(), c.Size())
	}
	// Continue observing after load — should accumulate.
	_, _ = restored.Observe("https://foo.com/users/3")
	if restored.HostCounts()["foo.com"] != 4 {
		t.Errorf("foo.com count after re-observe = %d", restored.HostCounts()["foo.com"])
	}
	_ = os.Remove(path)
}

func TestCorpusImprovementOverTime(t *testing.T) {
	c := NewCorpus()
	_, _ = c.Observe("https://foo.com/users/alice")
	first := c.Explain("https://foo.com/users/alice")
	if first[1].Classification != ClassStableLiteral {
		t.Errorf("first[1] = %q", first[1].Classification)
	}
	for _, n := range []string{"bob", "carol", "dave", "erin", "frank", "gina", "hank", "ivan", "jane", "kara", "liam"} {
		_, _ = c.Observe("https://foo.com/users/" + n)
	}
	later := c.Explain("https://foo.com/users/alice")
	if later[1].Classification != ClassCorpusInferredVariable {
		t.Errorf("later[1] = %q", later[1].Classification)
	}
}
