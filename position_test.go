package iriq

import "testing"

func TestPathPositionConstructor(t *testing.T) {
	p := PathPosition("foo.com", "/users")
	if !p.IsPath() {
		t.Errorf("IsPath = false, want true")
	}
	if p.Host != "foo.com" || p.Scope != ScopePath || p.Locator != "/users" {
		t.Errorf("unexpected fields: %+v", p)
	}
}

func TestQueryPositionConstructor(t *testing.T) {
	p := QueryPosition("foo.com", "page")
	if !p.IsQuery() {
		t.Errorf("IsQuery = false, want true")
	}
	if p.Host != "foo.com" || p.Scope != ScopeQuery || p.Locator != "page" {
		t.Errorf("unexpected fields: %+v", p)
	}
}

func TestPositionValueEquality(t *testing.T) {
	a := PathPosition("foo.com", "/u")
	b := PathPosition("foo.com", "/u")
	c := PathPosition("bar.com", "/u")
	if a != b {
		t.Errorf("equal positions did not compare equal: %v vs %v", a, b)
	}
	if a == c {
		t.Errorf("distinct hosts compared equal: %v vs %v", a, c)
	}
}

func TestPositionHashableAsMapKey(t *testing.T) {
	m := map[Position]int{}
	m[PathPosition("foo.com", "/u")] = 1
	if got := m[PathPosition("foo.com", "/u")]; got != 1 {
		t.Errorf("map lookup with equal-value Position = %d, want 1", got)
	}
}

func TestPathAndQueryDifferEvenWithSameLocator(t *testing.T) {
	pp := PathPosition("x", "name")
	qp := QueryPosition("x", "name")
	if pp == qp {
		t.Errorf("path and query with same locator compared equal")
	}
}
