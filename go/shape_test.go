package iriq

import "testing"

func TestShapeFromSegments(t *testing.T) {
	s := ShapeFromSegments([]string{"users", "123"}, nil)
	if len(s.Entries) != 2 {
		t.Fatalf("Entries len = %d, want 2", len(s.Entries))
	}
	if s.Entries[0].Type != TypeLiteral || s.Entries[1].Type != TypeInteger {
		t.Errorf("entry types = %v, want [literal integer]",
			[]SegmentType{s.Entries[0].Type, s.Entries[1].Type})
	}
}

func TestShapeRender(t *testing.T) {
	s := ShapeFromSegments([]string{"users", "123", "orders", "456"}, nil)
	if got := s.Render(ShapeRenderOptions{}); got != "/users/{user_id}/orders/{order_id}" {
		t.Errorf("default render = %q", got)
	}
	if got := s.Render(ShapeRenderOptions{HintsOff: true}); got != "/users/{integer}/orders/{integer}" {
		t.Errorf("hints-off render = %q", got)
	}
}

func TestShapeCanonicalRenders(t *testing.T) {
	dated := ShapeFromSegments([]string{"events", "2024/01/15"}, nil)
	if got := dated.Render(ShapeRenderOptions{CanonicalDates: true}); got != "/events/2024-01-15" {
		t.Errorf("canonical date render = %q", got)
	}
	curr := ShapeFromSegments([]string{"pricing", "usd"}, nil)
	if got := curr.Render(ShapeRenderOptions{CanonicalCurrencies: true}); got != "/pricing/USD" {
		t.Errorf("canonical currency render = %q", got)
	}
}

func TestShapeEqual(t *testing.T) {
	a := ShapeFromSegments([]string{"users", "1"}, nil)
	b := ShapeFromSegments([]string{"users", "999"}, nil)
	c := ShapeFromSegments([]string{"posts", "1"}, nil)
	if !a.Equal(b) {
		t.Errorf("different literal values should still be equal shape: %q vs %q", a, b)
	}
	if a.Equal(c) {
		t.Errorf("different literals should not be equal: %q vs %q", a, c)
	}
}

func TestShapeEmpty(t *testing.T) {
	if got := ShapeFromSegments(nil, nil).Render(ShapeRenderOptions{}); got != "/" {
		t.Errorf("empty shape render = %q, want /", got)
	}
}
