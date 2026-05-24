package iriq

import "testing"

func TestNormalizeBasic(t *testing.T) {
	cases := map[string]string{
		"https://foo.com/users/123":                  "https://foo.com/users/{user_id}",
		"https://foo.com/users/123/orders/456":       "https://foo.com/users/{user_id}/orders/{order_id}",
		"HTTPS://FOO.COM:443/Bar":                    "https://foo.com/Bar",
		"https://foo.com/posts/abc-123":              "https://foo.com/posts/{post_id}",
		"https://foo.com/search?q=hi&page=2":         "https://foo.com/search?page={integer_id}&q=hi",
		"urn:isbn:0451450523":                        "urn:isbn:{isbn_id}",
		"urn:uuid:f47ac10b-58cc-4372-a567-0e02b2c3d479": "urn:uuid:{uuid_uuid}",
	}
	for in, want := range cases {
		got, err := Normalize(in)
		if err != nil {
			t.Fatalf("Normalize(%q): %v", in, err)
		}
		if got != want {
			t.Errorf("Normalize(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestNormalizeNoHints(t *testing.T) {
	got, _ := NormalizeWith("https://foo.com/users/123", DefaultClassifier, false)
	want := "https://foo.com/users/{integer_id}"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}
