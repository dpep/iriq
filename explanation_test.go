package iriq

import "testing"

func TestExplainURL(t *testing.T) {
	got, err := Explain("https://foo.com/users/123/orders/456")
	if err != nil {
		t.Fatal(err)
	}
	want := []SegmentHint{
		{Value: "users", Type: TypeLiteral, Variable: false, Hint: ""},
		{Value: "123", Type: TypeIntegerID, Variable: true, Hint: "user_id"},
		{Value: "orders", Type: TypeLiteral, Variable: false, Hint: ""},
		{Value: "456", Type: TypeIntegerID, Variable: true, Hint: "order_id"},
	}
	if len(got) != len(want) {
		t.Fatalf("len(got)=%d want %d", len(got), len(want))
	}
	for i, w := range want {
		if got[i] != w {
			t.Errorf("entry[%d] = %#v want %#v", i, got[i], w)
		}
	}
}

func TestExplainURN(t *testing.T) {
	got, _ := Explain("urn:isbn:0451450523")
	if len(got) != 2 {
		t.Fatalf("len = %d", len(got))
	}
	if got[1].Type != TypeIntegerID {
		t.Errorf("got %#v", got[1])
	}
	if got[1].Hint != "isbn_id" {
		t.Errorf("hint = %q", got[1].Hint)
	}
}
