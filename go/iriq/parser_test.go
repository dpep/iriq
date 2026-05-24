package iriq

import (
	"reflect"
	"strings"
	"testing"
)

func TestParserStandardURL(t *testing.T) {
	iri, err := Parse("https://foo.com/users/123")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if iri.Scheme != "https" {
		t.Errorf("scheme = %q, want https", iri.Scheme)
	}
	if iri.Host != "foo.com" {
		t.Errorf("host = %q, want foo.com", iri.Host)
	}
	if iri.Port != 0 {
		t.Errorf("port = %d, want 0", iri.Port)
	}
	if !reflect.DeepEqual(iri.PathSegments, []string{"users", "123"}) {
		t.Errorf("path_segments = %#v", iri.PathSegments)
	}
	if iri.QueryParams.Len() != 0 {
		t.Errorf("query_params not empty: %#v", iri.QueryParams)
	}
	if iri.Fragment != "" {
		t.Errorf("fragment = %q", iri.Fragment)
	}
	if !iri.IsURL() {
		t.Errorf("expected URL kind")
	}
}

func TestParserLowercasesSchemeAndHost(t *testing.T) {
	iri, err := Parse("HTTPS://FOO.COM/Bar")
	if err != nil {
		t.Fatal(err)
	}
	if iri.Scheme != "https" || iri.Host != "foo.com" {
		t.Errorf("got %q %q", iri.Scheme, iri.Host)
	}
	if !reflect.DeepEqual(iri.PathSegments, []string{"Bar"}) {
		t.Errorf("path_segments = %#v", iri.PathSegments)
	}
}

func TestParserDropsDefaultPorts(t *testing.T) {
	for _, in := range []string{"https://foo.com:443/", "http://foo.com:80/"} {
		iri, err := Parse(in)
		if err != nil {
			t.Fatal(err)
		}
		if iri.Port != 0 {
			t.Errorf("%s: port = %d", in, iri.Port)
		}
	}
}

func TestParserKeepsNonDefaultPort(t *testing.T) {
	iri, _ := Parse("https://foo.com:8443/")
	if iri.Port != 8443 {
		t.Errorf("port = %d", iri.Port)
	}
}

func TestParserPreservesOriginal(t *testing.T) {
	iri, _ := Parse("  https://Foo.com/  ")
	if iri.Original != "  https://Foo.com/  " {
		t.Errorf("original = %q", iri.Original)
	}
}

func TestParserDotSegments(t *testing.T) {
	iri, _ := Parse("https://foo.com/a/./b/../c")
	if !reflect.DeepEqual(iri.PathSegments, []string{"a", "c"}) {
		t.Errorf("path_segments = %#v", iri.PathSegments)
	}
}

func TestParserDuplicateSlashes(t *testing.T) {
	iri, _ := Parse("https://foo.com//a///b")
	if !reflect.DeepEqual(iri.PathSegments, []string{"a", "b"}) {
		t.Errorf("path_segments = %#v", iri.PathSegments)
	}
}

func TestParserQueryParams(t *testing.T) {
	iri, _ := Parse("https://foo.com/q?a=1&b=hello&c=")
	want := map[string]string{"a": "1", "b": "hello", "c": ""}
	if !reflect.DeepEqual(iri.QueryParams.ToMap(), want) {
		t.Errorf("query_params = %#v", iri.QueryParams.ToMap())
	}
}

func TestParserFragment(t *testing.T) {
	iri, _ := Parse("https://foo.com/x#top")
	if iri.Fragment != "top" {
		t.Errorf("fragment = %q", iri.Fragment)
	}
}

func TestParserSchemeLessHost(t *testing.T) {
	iri, _ := Parse("foo.com/users/456")
	if iri.Scheme != "https" || iri.Host != "foo.com" {
		t.Errorf("%q %q", iri.Scheme, iri.Host)
	}
	if !reflect.DeepEqual(iri.PathSegments, []string{"users", "456"}) {
		t.Errorf("path_segments = %#v", iri.PathSegments)
	}
}

func TestParserURN(t *testing.T) {
	iri, _ := Parse("urn:isbn:0451450523")
	if !iri.IsURN() {
		t.Fatal("expected urn")
	}
	if iri.Scheme != "urn" || iri.NSS != "isbn:0451450523" {
		t.Errorf("scheme=%q nss=%q", iri.Scheme, iri.NSS)
	}
	if iri.Host != "" || len(iri.PathSegments) != 0 {
		t.Errorf("urn shouldn't have host/path_segments")
	}
}

func TestParserUnicodeIRI(t *testing.T) {
	iri, err := Parse("https://例え.テスト/こんにちは")
	if err != nil {
		t.Fatal(err)
	}
	if iri.Host != "例え.テスト" {
		t.Errorf("host = %q", iri.Host)
	}
	if !reflect.DeepEqual(iri.PathSegments, []string{"こんにちは"}) {
		t.Errorf("path_segments = %#v", iri.PathSegments)
	}
}

func TestParserErrors(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"   ", "empty"},
		{"just-some-token", "cannot parse"},
	}
	for _, c := range cases {
		_, err := Parse(c.in)
		if err == nil {
			t.Errorf("Parse(%q) expected error", c.in)
			continue
		}
		if !strings.Contains(err.Error(), c.want) {
			t.Errorf("Parse(%q) error = %q, want substring %q", c.in, err.Error(), c.want)
		}
	}
}

func TestCanonicalRoundtrip(t *testing.T) {
	cases := []struct{ in, want string }{
		{"https://foo.com/users/123", "https://foo.com/users/123"},
		{"https://foo.com", "https://foo.com"},
		{"https://foo.com/", "https://foo.com"},
		{"https://foo.com:8443/x?a=1#top", "https://foo.com:8443/x?a=1#top"},
		{"urn:isbn:0451450523", "urn:isbn:0451450523"},
		{"foo.com/users/1", "https://foo.com/users/1"},
		{"HTTPS://FOO.COM:443/Bar", "https://foo.com/Bar"},
	}
	for _, c := range cases {
		iri, err := Parse(c.in)
		if err != nil {
			t.Fatalf("Parse(%q): %v", c.in, err)
		}
		if got := iri.Canonical(); got != c.want {
			t.Errorf("canonical(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
