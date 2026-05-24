package iriq

import "testing"

func TestSingularize(t *testing.T) {
	cases := map[string]string{
		// plain
		"users": "user", "posts": "post", "orders": "order", "comments": "comment",
		"articles": "article", "items": "item", "projects": "project",
		// -ies
		"categories": "category", "companies": "company", "cities": "city", "libraries": "library",
		// -ses/-es
		"addresses": "address", "statuses": "status", "classes": "class",
		"boxes": "box", "buses": "bus", "churches": "church",
		// latin-ish
		"matrices": "matrix", "indices": "index", "vertices": "vertex",
		"octopi": "octopus", "analyses": "analysis", "diagnoses": "diagnosis", "theses": "thesis",
		// -ves
		"knives": "knife", "leaves": "leaf", "wolves": "wolf",
		// irregulars
		"people": "person", "children": "child", "men": "man",
		"women": "woman", "mice": "mouse",
		// -ice
		"lice": "louse",
		// -oes
		"heroes": "hero", "tomatoes": "tomato",
		// uncountable
		"news": "news", "fish": "fish", "sheep": "sheep",
		"data": "data", "person": "person",
	}
	for in, want := range cases {
		if got := Singularize(in); got != want {
			t.Errorf("Singularize(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSingularizeCasePreservation(t *testing.T) {
	cases := map[string]string{
		"Users":  "User",
		"USERS":  "USER",
		"People": "Person",
		"":       "",
	}
	for in, want := range cases {
		if got := Singularize(in); got != want {
			t.Errorf("Singularize(%q) = %q, want %q", in, got, want)
		}
	}
}
