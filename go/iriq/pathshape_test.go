package iriq

import "testing"

func TestPathShapeFor(t *testing.T) {
	cases := []struct {
		segments []string
		hints    bool
		want     string
	}{
		{nil, true, "/"},
		{[]string{}, true, "/"},
		{[]string{"users", "123"}, true, "/users/{user_id}"},
		{[]string{"users", "123"}, false, "/users/{integer_id}"},
		{[]string{"users", "123", "orders", "456"}, true, "/users/{user_id}/orders/{order_id}"},
		{[]string{"login"}, true, "/login"},
		{[]string{"posts", "abc-123"}, true, "/posts/{post_id}"},
		{[]string{"posts", "abc-123"}, false, "/posts/{slug}"},
	}
	for _, c := range cases {
		if got := PathShapeFor(c.segments, c.hints); got != c.want {
			t.Errorf("PathShapeFor(%v, hints=%v) = %q, want %q", c.segments, c.hints, got, c.want)
		}
	}
}
