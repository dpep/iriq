package iriq

import (
	"sort"
	"testing"
)

func TestClustererGroupsByShape(t *testing.T) {
	c := NewClusterer(nil)
	for _, in := range []string{
		"https://foo.com/users/1",
		"https://foo.com/users/2",
		"https://foo.com/posts/abc-123",
	} {
		if _, err := c.Add(in, ""); err != nil {
			t.Fatalf("Add(%q): %v", in, err)
		}
	}
	shapes := []string{}
	for _, cl := range c.Clusters() {
		shapes = append(shapes, cl.Shape)
	}
	sort.Strings(shapes)
	want := []string{"/posts/{post_id}", "/users/{user_id}"}
	if len(shapes) != 2 || shapes[0] != want[0] || shapes[1] != want[1] {
		t.Errorf("shapes = %v, want %v", shapes, want)
	}
	// Count for /users/{user_id} should be 2.
	for _, cl := range c.Clusters() {
		if cl.Shape == "/users/{user_id}" && cl.Count != 2 {
			t.Errorf("/users count = %d, want 2", cl.Count)
		}
	}
}

func TestClustererExplain(t *testing.T) {
	c := NewClusterer(nil)
	for _, n := range []string{"1", "2", "3"} {
		_, _ = c.Add("https://foo.com/users/"+n, "")
	}
	entries, err := c.Explain("https://foo.com/users/1")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Fatalf("len = %d", len(entries))
	}
	if !entries[0].Stable {
		t.Error("users should be stable")
	}
	if entries[1].Stable {
		t.Error("id should not be stable")
	}
}

func TestClustererURN(t *testing.T) {
	c := NewClusterer(nil)
	_, _ = c.Add("urn:isbn:0451450523", "")
	_, _ = c.Add("urn:isbn:9999999999", "")
	if c.Size() != 1 {
		t.Errorf("expected 1 cluster, got %d", c.Size())
	}
	for _, cl := range c.Clusters() {
		if cl.Shape != "urn:isbn:{isbn_id}" {
			t.Errorf("shape = %q", cl.Shape)
		}
	}
}
