package iriq

import "testing"

func TestClassifyCases(t *testing.T) {
	cases := map[string]SegmentType{
		"users":                                TypeLiteral,
		"Profile":                              TypeLiteral,
		"123":                                  TypeInteger,
		"0":                                    TypeInteger,
		"9999999":                              TypeInteger,
		"f47ac10b-58cc-4372-a567-0e02b2c3d479": TypeUUID,
		"2024-05-23":                           TypeDate,
		"2024-05-23T10:30:00Z":                 TypeTimestamp,
		"2024-05-23 10:30:00":                  TypeTimestamp,
		"1716470400":                           TypeTimestamp,
		"1716470400000":                        TypeTimestamp,
		"d41d8cd98f00b204e9800998ecf8427e":     TypeHash,
		"my-cool-post":                         TypeSlug,
		"my_cool_post":                         TypeSlug,
		"abc123XYZ":                            TypeOpaqueID,
		"こんにちは":                                TypeLiteral,
		"":                                     TypeLiteral,
	}
	for in, want := range cases {
		if got := DefaultClassifier.Classify(in); got != want {
			t.Errorf("Classify(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestVariable(t *testing.T) {
	if DefaultClassifier.Variable(TypeLiteral) {
		t.Error("literal should not be variable")
	}
	for _, t2 := range []SegmentType{TypeInteger, TypeUUID, TypeDate, TypeTimestamp, TypeHash, TypeSlug, TypeOpaqueID} {
		if !DefaultClassifier.Variable(t2) {
			t.Errorf("%q should be variable", t2)
		}
	}
}
