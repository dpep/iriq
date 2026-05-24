package iriq

import (
	"reflect"
	"testing"
)

func extract(text string) []string {
	out := []string{}
	for _, iri := range NewExtractor().Extract(text) {
		out = append(out, iri.Canonical())
	}
	return out
}

func extractStrict(text string) []string {
	e := &Extractor{SchemeLess: false}
	out := []string{}
	for _, iri := range e.Extract(text) {
		out = append(out, iri.Canonical())
	}
	return out
}

func TestExtractorEmpty(t *testing.T) {
	if got := extract(""); len(got) != 0 {
		t.Errorf("empty: %#v", got)
	}
	if got := extract("just some prose, no URLs here"); len(got) != 0 {
		t.Errorf("prose: %#v", got)
	}
}

func TestExtractorBasic(t *testing.T) {
	cases := map[string][]string{
		"Visit http://foo.com today":  {"http://foo.com"},
		"Visit https://foo.com today": {"https://foo.com"},
		"ftp://files.example.com and wss://chat.example.com": {
			"ftp://files.example.com", "wss://chat.example.com",
		},
		"First https://a.com then https://b.com and https://c.com": {
			"https://a.com", "https://b.com", "https://c.com",
		},
	}
	for in, want := range cases {
		if got := extract(in); !reflect.DeepEqual(got, want) {
			t.Errorf("extract(%q) = %#v, want %#v", in, got, want)
		}
	}
}

func TestExtractorURNs(t *testing.T) {
	cases := map[string][]string{
		"See urn:isbn:0451450523 for details": {"urn:isbn:0451450523"},
		"Session urn:uuid:f47ac10b-58cc-4372-a567-0e02b2c3d479 expired": {
			"urn:uuid:f47ac10b-58cc-4372-a567-0e02b2c3d479",
		},
	}
	for in, want := range cases {
		if got := extract(in); !reflect.DeepEqual(got, want) {
			t.Errorf("extract(%q) = %#v, want %#v", in, got, want)
		}
	}
}

func TestExtractorTrimsPunctuation(t *testing.T) {
	cases := map[string][]string{
		"Visit https://foo.com.":         {"https://foo.com"},
		"https://foo.com, and then more": {"https://foo.com"},
		"Look at https://foo.com!":       {"https://foo.com"},
		"Did you see https://foo.com?":   {"https://foo.com"},
		"https://foo.com; next thing":    {"https://foo.com"},
		`"https://foo.com",`:             {"https://foo.com"},
	}
	for in, want := range cases {
		if got := extract(in); !reflect.DeepEqual(got, want) {
			t.Errorf("extract(%q) = %#v, want %#v", in, got, want)
		}
	}
}

func TestExtractorBalancedBrackets(t *testing.T) {
	cases := map[string][]string{
		"See https://en.wikipedia.org/wiki/Ruby_(programming_language)": {"https://en.wikipedia.org/wiki/Ruby_(programming_language)"},
		"(see https://foo.com)":                                         {"https://foo.com"},
		"[https://foo.com]":                                             {"https://foo.com"},
		"(see https://en.wikipedia.org/wiki/Foo_(bar))":                 {"https://en.wikipedia.org/wiki/Foo_(bar)"},
	}
	for in, want := range cases {
		if got := extract(in); !reflect.DeepEqual(got, want) {
			t.Errorf("extract(%q) = %#v, want %#v", in, got, want)
		}
	}
}

func TestExtractorQuotesAngles(t *testing.T) {
	cases := map[string][]string{
		`href="https://foo.com"`:                {"https://foo.com"},
		`href='https://foo.com'`:                {"https://foo.com"},
		"`https://foo.com`":                     {"https://foo.com"},
		"<https://foo.com>":                     {"https://foo.com"},
		`{"url":"https://foo.com/x?a=1"}`:       {"https://foo.com/x?a=1"},
	}
	for in, want := range cases {
		if got := extract(in); !reflect.DeepEqual(got, want) {
			t.Errorf("extract(%q) = %#v, want %#v", in, got, want)
		}
	}
}

func TestExtractorWordBoundary(t *testing.T) {
	if got := extract("seehttps://foo.com"); len(got) != 0 {
		t.Errorf("word-boundary should reject: %#v", got)
	}
	if got := extract("/path/tohttps://foo.com"); len(got) != 0 {
		t.Errorf("path-stuck should reject: %#v", got)
	}
	if got := extract(":https://foo.com"); !reflect.DeepEqual(got, []string{"https://foo.com"}) {
		t.Errorf("got %#v", got)
	}
}

func TestExtractorComplex(t *testing.T) {
	cases := map[string][]string{
		"https://foo.com:8443/x?a=1&b=2#top":               {"https://foo.com:8443/x?a=1&b=2#top"},
		"https://maps.example.com/?q=37.7,-122.4 next":     {"https://maps.example.com/?q=37.7"},
		"local: https://127.0.0.1:8080/x":                  {"https://127.0.0.1:8080/x"},
		"Read https://foo.com/file.txt right now":          {"https://foo.com/file.txt"},
		"Read https://foo.com/file.txt.":                   {"https://foo.com/file.txt"},
		"see https://foo.com/path%20with%20spaces today":   {"https://foo.com/path%20with%20spaces"},
		"https://a.b.c.d.foo.com/x":                        {"https://a.b.c.d.foo.com/x"},
		"https://foo.com's API is great":                   {"https://foo.com"},
	}
	for in, want := range cases {
		if got := extract(in); !reflect.DeepEqual(got, want) {
			t.Errorf("extract(%q) = %#v, want %#v", in, got, want)
		}
	}
}

func TestExtractorUnicode(t *testing.T) {
	if got := extract("Visit https://例え.テスト/こんにちは today"); !reflect.DeepEqual(got, []string{"https://例え.テスト/こんにちは"}) {
		t.Errorf("got %#v", got)
	}
	if got := extract("「https://例え.テスト/こんにちは」を見て"); !reflect.DeepEqual(got, []string{"https://例え.テスト/こんにちは"}) {
		t.Errorf("got %#v", got)
	}
	if got := extract("She said “https://foo.com” loudly"); !reflect.DeepEqual(got, []string{"https://foo.com"}) {
		t.Errorf("got %#v", got)
	}
	if got := extract("Сайт https://россия.рф/о-нас здесь"); !reflect.DeepEqual(got, []string{"https://россия.рф/о-нас"}) {
		t.Errorf("got %#v", got)
	}
}

func TestExtractorMultiline(t *testing.T) {
	text := `Some preamble.

- https://a.com
- https://b.com (with note)
- [Markdown link](https://c.com)
- <https://d.com>
- urn:isbn:0451450523

Closing thoughts about https://e.com.
`
	want := []string{"https://a.com", "https://b.com", "https://c.com", "https://d.com", "urn:isbn:0451450523", "https://e.com"}
	if got := extract(text); !reflect.DeepEqual(got, want) {
		t.Errorf("got %#v want %#v", got, want)
	}
}

func TestExtractorSchemeless(t *testing.T) {
	// Scheme-less on (default).
	if got := extract("visit foo.com/users today"); !reflect.DeepEqual(got, []string{"https://foo.com/users"}) {
		t.Errorf("got %#v", got)
	}
	if got := extract("visit foo.com today"); len(got) != 0 {
		t.Errorf("bare host shouldn't match: %#v", got)
	}
	if got := extract("visit foo.xyz/path today"); len(got) != 0 {
		t.Errorf("non-allowlist TLD: %#v", got)
	}
	if got := extract("a.com/x and b.org/y and c.ai/z"); !reflect.DeepEqual(got, []string{"https://a.com/x", "https://b.org/y", "https://c.ai/z"}) {
		t.Errorf("got %#v", got)
	}
	if got := extract("contact user@foo.com/path today"); len(got) != 0 {
		t.Errorf("should skip email: %#v", got)
	}
	// Strict mode.
	if got := extractStrict("visit foo.com/users today"); len(got) != 0 {
		t.Errorf("strict mode shouldn't match: %#v", got)
	}
}

func TestExtractorFalsePositives(t *testing.T) {
	cases := []string{
		"see ./README.md and /usr/local/bin",
		"user@host:port/path",
		"Acme Inc. (acme.com is the corporate page)",
		"rsync user@host.com:/var/log/ to backup",
		"contact user@example.com today",
		"write to mailto:user@example.com",
		"textseehttps://foo.com",
	}
	for _, in := range cases {
		if got := extract(in); len(got) != 0 {
			t.Errorf("extract(%q) = %#v, want []", in, got)
		}
	}
}

func TestExtractorDuplicates(t *testing.T) {
	if got := extract("https://a.com then https://a.com again"); !reflect.DeepEqual(got, []string{"https://a.com", "https://a.com"}) {
		t.Errorf("got %#v", got)
	}
	got := NewExtractor().ExtractStrings("https://b.com first then https://a.com then https://b.com again")
	want := []string{"https://b.com", "https://a.com"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %#v want %#v", got, want)
	}
}
