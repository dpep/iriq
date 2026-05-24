package iriq

import "strings"

// Kind discriminates between URL-style and URN-style identifiers.
type Kind int

const (
	KindURL Kind = iota
	KindURN
)

func (k Kind) String() string {
	switch k {
	case KindURN:
		return "urn"
	default:
		return "url"
	}
}

// Identifier is a parsed IRI. For URN-style inputs (urn:isbn:0451450523)
// only Scheme and NSS are populated; Host/Path are empty.
type Identifier struct {
	Original     string
	Scheme       string
	Host         string
	Port         int // 0 == unset
	Path         string
	PathSegments []string
	Query        string
	QueryParams  *OrderedMap
	Fragment     string
	NSS          string
	Kind         Kind
}

func (i *Identifier) IsURN() bool { return i.Kind == KindURN }
func (i *Identifier) IsURL() bool { return i.Kind == KindURL }

// Canonical rebuilds an IRI-like string from the parsed fields. Preserves
// Unicode display form (no punycode / percent-encoding pass).
func (i *Identifier) Canonical() string {
	if i.IsURN() {
		return "urn:" + i.NSS
	}
	var b strings.Builder
	if i.Scheme != "" {
		b.WriteString(i.Scheme)
		b.WriteString("://")
	}
	if i.Host != "" {
		b.WriteString(i.Host)
	}
	if i.Port != 0 {
		b.WriteByte(':')
		b.WriteString(itoa(i.Port))
	}
	hasQuery := i.Query != ""
	hasFrag := i.Fragment != ""
	if len(i.PathSegments) > 0 {
		b.WriteByte('/')
		b.WriteString(strings.Join(i.PathSegments, "/"))
	} else if hasQuery || hasFrag {
		b.WriteByte('/')
	}
	if hasQuery {
		b.WriteByte('?')
		b.WriteString(i.Query)
	}
	if hasFrag {
		b.WriteByte('#')
		b.WriteString(i.Fragment)
	}
	return b.String()
}

func (i *Identifier) String() string { return i.Canonical() }

func (i *Identifier) Equal(other *Identifier) bool {
	if other == nil {
		return false
	}
	return i.Canonical() == other.Canonical()
}

// itoa is a small int-to-string helper to avoid importing strconv where we only
// need a single small-integer rendering for port.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
