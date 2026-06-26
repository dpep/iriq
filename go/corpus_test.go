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
	if last.Value != "123" || last.Type != TypeInteger {
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
	if got := c.RawShapeCounts()["/users/{integer}"]; got != 2 {
		t.Errorf("/users/{integer} = %d", got)
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
	if stats.TypeCounts[TypeInteger] != 2 || stats.TypeCounts[TypeLiteral] != 1 {
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

func TestCorpusQueryParamInference(t *testing.T) {
	c := NewCorpus()
	for i := 0; i < 10; i++ {
		// Pad day to 2 digits — dateSlashRE matches 2-digit day/month strictly.
		day := i + 1
		dayStr := itoa(day)
		if day < 10 {
			dayStr = "0" + dayStr
		}
		_, _ = c.Observe("https://foo.com/search?q=widget&page=" + itoa(i+1) + "&since=2024/01/" + dayStr)
	}
	got, _ := c.Normalize("https://foo.com/search?q=hammer&page=42&since=2024-02-15")
	want := "https://foo.com/search?page={integer}&q=hammer&since=2024-02-15"
	if got != want {
		t.Errorf("Normalize: got %q, want %q", got, want)
	}

	params := c.ParamsFor("https://foo.com/search")
	if len(params) != 3 {
		t.Fatalf("ParamsFor: got %d params, want 3", len(params))
	}
	byName := map[string]ParamSummary{}
	for _, p := range params {
		byName[p.Name] = p
	}
	if byName["page"].Type != TypeInteger {
		t.Errorf("page type = %q, want integer", byName["page"].Type)
	}
	if byName["since"].Type != TypeDate {
		t.Errorf("since type = %q, want date", byName["since"].Type)
	}
	if byName["q"].Cardinality != 1 {
		t.Errorf("q cardinality = %d, want 1", byName["q"].Cardinality)
	}
}

func TestCorpusParamLadder(t *testing.T) {
	// constant: a single observed value is rendered as-is.
	c := NewCorpus()
	for i := 0; i < 10; i++ {
		_, _ = c.Observe("https://foo.com/x?format=json")
	}
	if got := c.ParamsFor("https://foo.com/x")[0].Type; got != TypeLiteral {
		t.Errorf("constant param type = %q, want literal", got)
	}
	got, _ := c.Normalize("https://foo.com/x?format=json")
	if got != "https://foo.com/x?format=json" {
		t.Errorf("constant render = %q, want value preserved", got)
	}

	// A lone value stays a constant even past the enum observation threshold.
	c = NewCorpus()
	for i := 0; i < 40; i++ {
		_, _ = c.Observe("https://foo.com/c?format=json")
	}
	if got := c.ParamsFor("https://foo.com/c")[0].Type; got != TypeLiteral {
		t.Errorf("constant past threshold type = %q, want literal (not enum)", got)
	}

	// string: varies across many distinct literals, below the enum bar.
	c = NewCorpus()
	for _, v := range []string{"asc", "desc", "name", "created", "updated"} {
		_, _ = c.Observe("https://foo.com/y?sort=" + v)
	}
	if got := c.ParamsFor("https://foo.com/y")[0].Type; got != TypeString {
		t.Errorf("varying literal type = %q, want string", got)
	}
	got, _ = c.Normalize("https://foo.com/y?sort=relevance")
	if got != "https://foo.com/y?sort={string}" {
		t.Errorf("string render = %q, want {string}", got)
	}

	// enum: a bounded set, well supported, graduates from string.
	c = NewCorpus()
	for i := 0; i < 20; i++ {
		_, _ = c.Observe("https://foo.com/z?state=on")
		_, _ = c.Observe("https://foo.com/z?state=off")
	}
	if got := c.ParamsFor("https://foo.com/z")[0].Type; got != TypeEnum {
		t.Errorf("bounded param type = %q, want enum", got)
	}
}

func TestCorpusEnumStragglerRobust(t *testing.T) {
	// A single one-off value must not knock an established enum back down.
	c := NewCorpus()
	for i := 0; i < 30; i++ {
		_, _ = c.Observe("https://foo.com/posts?status=published")
	}
	for i := 0; i < 20; i++ {
		_, _ = c.Observe("https://foo.com/posts?status=draft")
	}
	_, _ = c.Observe("https://foo.com/posts?status=typo") // straggler
	p := c.ParamsFor("https://foo.com/posts")[0]
	if p.Type != TypeEnum {
		t.Errorf("type = %q, want enum despite straggler", p.Type)
	}
	if len(p.Values) != 2 {
		t.Errorf("enum values = %v, want the 2 established members only", p.Values)
	}
}

func TestCorpusParamConfidence(t *testing.T) {
	c := NewCorpus()
	_, _ = c.Observe("https://foo.com/x?a=1")
	low := c.ParamsFor("https://foo.com/x")[0].Confidence
	for i := 0; i < 1000; i++ {
		_, _ = c.Observe("https://foo.com/x?a=1")
	}
	high := c.ParamsFor("https://foo.com/x")[0].Confidence
	if !(low > 0 && low < high && high <= 1.0) {
		t.Errorf("confidence should rise within (0,1]: low=%v high=%v", low, high)
	}
	if high <= 0.9 {
		t.Errorf("confidence with abundant evidence = %v, want > 0.9", high)
	}
}

func TestCanonicalDate(t *testing.T) {
	cases := map[string]string{
		"2024-01-15": "2024-01-15",
		"2024/01/15": "2024-01-15",
		"20240115":   "2024-01-15",
		"12345678":   "", // not a plausible date — year 1234
		"abc":        "",
		"":           "",
	}
	for in, want := range cases {
		if got := CanonicalDate(in); got != want {
			t.Errorf("CanonicalDate(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCorpusFloatAndNumeric(t *testing.T) {
	// Pure floats stay :float.
	c := NewCorpus()
	for i := 0; i < 20; i++ {
		_, _ = c.Observe("https://foo.com/api?amt=" + itoa(i+1) + ".99")
	}
	got, _ := c.Normalize("https://foo.com/api?amt=99.99")
	if got != "https://foo.com/api?amt={float}" {
		t.Errorf("pure float: got %q", got)
	}

	// Mixed ints + floats promote to :number.
	c2 := NewCorpus()
	for i := 0; i < 60; i++ {
		_, _ = c2.Observe("https://foo.com/api?amt=" + itoa(i+1) + ".5")
	}
	for i := 0; i < 40; i++ {
		_, _ = c2.Observe("https://foo.com/api?amt=" + itoa(i+100))
	}
	got2, _ := c2.Normalize("https://foo.com/api?amt=12.34")
	if got2 != "https://foo.com/api?amt={number}" {
		t.Errorf("mixed: got %q", got2)
	}
	ps := c2.ParamsFor("https://foo.com/api")
	if len(ps) != 1 || ps[0].Type != TypeNumber {
		t.Errorf("ParamsFor: got %+v", ps)
	}
}

func TestCorpusHostStrategy(t *testing.T) {
	// Registrable collapses subdomains.
	c := NewCorpus()
	c.HostStrategy = HostStrategyRegistrable
	_, _ = c.Observe("https://api.foo.com/users/1")
	_, _ = c.Observe("https://app.foo.com/users/2")
	if got := c.HostCounts(); got["foo.com"] != 2 {
		t.Errorf("registrable host_counts: %v", got)
	}
	if c.Size() != 1 {
		t.Errorf("registrable clusters: %d, want 1", c.Size())
	}

	// Multi-label TLD.
	c2 := NewCorpus()
	c2.HostStrategy = HostStrategyRegistrable
	_, _ = c2.Observe("https://blog.example.co.uk/posts/1")
	_, _ = c2.Observe("https://news.example.co.uk/posts/2")
	if got := c2.HostCounts(); got["example.co.uk"] != 2 {
		t.Errorf("co.uk host_counts: %v", got)
	}

	// None pools across hosts.
	c3 := NewCorpus()
	c3.HostStrategy = HostStrategyNone
	_, _ = c3.Observe("https://foo.com/users/1")
	_, _ = c3.Observe("https://bar.io/users/2")
	if c3.Size() != 1 {
		t.Errorf("none clusters: %d, want 1", c3.Size())
	}
}

func TestRegistrableDomain(t *testing.T) {
	cases := map[string]string{
		"foo.com":            "foo.com",
		"api.foo.com":        "foo.com",
		"deep.api.foo.com":   "foo.com",
		"example.co.uk":      "example.co.uk",
		"news.example.co.uk": "example.co.uk",
		"foo.gov.au":         "foo.gov.au",
		"app.foo.gov.au":     "foo.gov.au",
		"localhost":          "localhost",
		"192.168.1.1":        "192.168.1.1",
		"":                   "",
	}
	for in, want := range cases {
		if got := RegistrableDomain(in); got != want {
			t.Errorf("RegistrableDomain(%q) = %q, want %q", in, got, want)
		}
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
