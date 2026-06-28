package iriq

import (
	"path/filepath"
	"reflect"
	"testing"
)

func TestOpenStorageByExtension(t *testing.T) {
	dir := t.TempDir()

	if s, err := OpenStorage("", 0); err != nil {
		t.Fatal(err)
	} else if _, ok := s.(*MemoryStorage); !ok {
		t.Errorf("nil path: got %T, want *MemoryStorage", s)
	}

	if s, err := OpenStorage(filepath.Join(dir, "c.json"), 0); err != nil {
		t.Fatal(err)
	} else if _, ok := s.(*JSONStorage); !ok {
		t.Errorf(".json: got %T, want *JSONStorage", s)
	}

	for _, ext := range []string{".db", ".sqlite", ".sqlite3"} {
		s, err := OpenStorage(filepath.Join(dir, "c"+ext), 0)
		if err != nil {
			t.Fatalf("%s: %v", ext, err)
		}
		if _, ok := s.(*SqliteStorage); !ok {
			t.Errorf("%s: got %T, want *SqliteStorage", ext, s)
		}
		_ = s.Close()
	}
}

func sqliteCorpusAt(t *testing.T) (*Corpus, string) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "corpus.db")
	c, err := OpenCorpus(path)
	if err != nil {
		t.Fatal(err)
	}
	return c, path
}

func TestSqliteParityWithMemory(t *testing.T) {
	inputs := []string{
		"https://foo.com/users/1",
		"https://foo.com/users/2",
		"https://foo.com/users/3",
		"https://foo.com/posts/abc-123/edit",
		"https://bar.com/x",
		"urn:isbn:0451450523",
	}

	mem := NewCorpus()
	sqlite, _ := sqliteCorpusAt(t)
	defer sqlite.Close()

	for _, in := range inputs {
		if _, err := mem.Observe(in); err != nil {
			t.Fatal(err)
		}
		if _, err := sqlite.Observe(in); err != nil {
			t.Fatal(err)
		}
	}

	if !reflect.DeepEqual(mem.HostCounts(), sqlite.HostCounts()) {
		t.Errorf("HostCounts:\n  mem: %v\n  db:  %v", mem.HostCounts(), sqlite.HostCounts())
	}
	if !reflect.DeepEqual(mem.PathLengthCounts(), sqlite.PathLengthCounts()) {
		t.Errorf("PathLengthCounts mismatch")
	}
	if !reflect.DeepEqual(mem.RawShapeCounts(), sqlite.RawShapeCounts()) {
		t.Errorf("RawShapeCounts mismatch")
	}
	if !reflect.DeepEqual(mem.FingerprintCounts(), sqlite.FingerprintCounts()) {
		t.Errorf("FingerprintCounts mismatch")
	}
	if mem.Size() != sqlite.Size() {
		t.Errorf("Size mismatch: mem=%d db=%d", mem.Size(), sqlite.Size())
	}

	ms := mem.StatsFor("foo.com", "/users")
	ds := sqlite.StatsFor("foo.com", "/users")
	if ms.Total != ds.Total {
		t.Errorf("Total: mem=%d db=%d", ms.Total, ds.Total)
	}
	if !reflect.DeepEqual(ms.ValueCounts, ds.ValueCounts) {
		t.Errorf("ValueCounts mismatch")
	}
	if !reflect.DeepEqual(ms.TypeCounts, ds.TypeCounts) {
		t.Errorf("TypeCounts mismatch")
	}
}

func TestSqliteCorpusInformedNormalize(t *testing.T) {
	sqlite, _ := sqliteCorpusAt(t)
	defer sqlite.Close()

	for _, n := range []string{"alice", "bob", "carol", "dave", "erin", "frank", "gina", "hank", "ivan", "jane"} {
		if _, err := sqlite.Observe("https://foo.com/users/" + n + "/profile"); err != nil {
			t.Fatal(err)
		}
	}
	got, _ := sqlite.Normalize("https://foo.com/users/zoe/profile")
	if got != "https://foo.com/users/{user}/profile" {
		t.Errorf("got %q", got)
	}
}

func TestSqlitePersistsAcrossReopen(t *testing.T) {
	_, path := sqliteCorpusAt(t)
	// re-open returns *Corpus
	c, _ := OpenCorpus(path)
	if _, err := c.Observe("https://foo.com/users/1"); err != nil {
		t.Fatal(err)
	}
	c.Close()

	c2, _ := OpenCorpus(path)
	defer c2.Close()
	if _, err := c2.Observe("https://foo.com/users/2"); err != nil {
		t.Fatal(err)
	}
	if c2.HostCounts()["foo.com"] != 2 {
		t.Errorf("foo.com = %d, want 2", c2.HostCounts()["foo.com"])
	}
	if c2.StatsFor("foo.com", "/users").Total != 2 {
		t.Errorf("position total != 2")
	}
}

func TestSqliteEnforcesValueCap(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "c.db")
	s, err := OpenSqliteStorage(path, 5)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	c := NewCorpusWithStorage(DefaultClassifier, s)
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

func TestSqliteCapsClusterExamples(t *testing.T) {
	sqlite, _ := sqliteCorpusAt(t)
	defer sqlite.Close()
	for i := 0; i < 30; i++ {
		_, _ = sqlite.Observe("https://foo.com/users/" + itoa(i))
	}
	cl := sqlite.Clusters()[0]
	if cl.Count != 30 {
		t.Errorf("count = %d", cl.Count)
	}
	if len(cl.Examples) != MaxClusterExamples {
		t.Errorf("examples = %d, want %d", len(cl.Examples), MaxClusterExamples)
	}
}

func TestSqliteDedupesClusterExamples(t *testing.T) {
	sqlite, _ := sqliteCorpusAt(t)
	defer sqlite.Close()
	for i := 0; i < 3; i++ {
		_, _ = sqlite.Observe("https://foo.com/users/1")
	}
	_, _ = sqlite.Observe("https://foo.com/users/2")

	cl := sqlite.Clusters()[0]
	if cl.Count != 4 {
		t.Errorf("count = %d, want 4", cl.Count)
	}
	got := []string{}
	for _, e := range cl.Examples {
		got = append(got, e.Canonical())
	}
	want := []string{"https://foo.com/users/1", "https://foo.com/users/2"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("examples = %v, want %v", got, want)
	}
}

func TestSqliteExportToJSON(t *testing.T) {
	sqlite, _ := sqliteCorpusAt(t)
	_, _ = sqlite.Observe("https://foo.com/users/1")
	_, _ = sqlite.Observe("https://foo.com/users/2")

	dir := t.TempDir()
	out := filepath.Join(dir, "exported.json")
	if err := sqlite.Save(out); err != nil {
		t.Fatal(err)
	}
	sqlite.Close()

	loaded, err := LoadCorpus(out)
	if err != nil {
		t.Fatal(err)
	}
	defer loaded.Close()
	if loaded.HostCounts()["foo.com"] != 2 {
		t.Errorf("exported HostCounts = %v", loaded.HostCounts())
	}
}
