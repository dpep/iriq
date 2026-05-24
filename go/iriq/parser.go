package iriq

import (
	"regexp"
	"strconv"
	"strings"
)

var (
	schemeRE  = regexp.MustCompile(`^([a-zA-Z][a-zA-Z0-9+\-.]*):`)
	hostishRE = regexp.MustCompile(`^(?P<host>[^/?#\s:]+\.[^/?#\s:]+|localhost)(?::(?P<port>\d+))?(?P<rest>[/?#].*)?$`)
	authRE    = regexp.MustCompile(`^(?P<host>[^/?#]+?)(?::(?P<port>\d+))?(?P<rest>[/?#].*)?$`)
)

var defaultPorts = map[string]int{
	"http":  80,
	"https": 443,
	"ftp":   21,
	"ws":    80,
	"wss":   443,
}

// Parse is the package-level entry point — mirrors Iriq.parse in Ruby.
func Parse(input string) (*Identifier, error) {
	return ParserParse(input)
}

// ParserParse parses an input string into an Identifier.
func ParserParse(input string) (*Identifier, error) {
	stripped := strings.TrimSpace(input)
	if stripped == "" {
		return nil, newParseError("input is empty")
	}

	if m := schemeRE.FindStringSubmatchIndex(stripped); m != nil {
		scheme := strings.ToLower(stripped[m[2]:m[3]])
		rest := stripped[m[1]:]
		switch {
		case scheme == "urn":
			return parseURN(input, rest)
		case strings.HasPrefix(rest, "//"):
			return parseAuthorityURL(input, scheme, rest[2:])
		default:
			// Opaque scheme (mailto:foo@bar). Keep NSS, mark URN-ish so we
			// don't pretend to know the host/path layout.
			return &Identifier{
				Original:     input,
				Scheme:       scheme,
				NSS:          rest,
				Kind:         KindURN,
				PathSegments: []string{},
				QueryParams:  NewOrderedMap(),
			}, nil
		}
	}

	if hostishRE.MatchString(stripped) {
		return parseAuthorityURL(input, "https", stripped)
	}
	return nil, newParseError("cannot parse " + strconv.Quote(input) + ": no scheme and no host-like prefix")
}

func parseURN(original, rest string) (*Identifier, error) {
	if rest == "" {
		return nil, newParseError("urn missing namespace")
	}
	return &Identifier{
		Original:     original,
		Scheme:       "urn",
		NSS:          rest,
		Kind:         KindURN,
		PathSegments: []string{},
		QueryParams:  NewOrderedMap(),
	}, nil
}

func parseAuthorityURL(original, scheme, remainder string) (*Identifier, error) {
	m := matchNamed(hostishRE, remainder)
	if m == nil {
		m = matchNamed(authRE, remainder)
	}
	if m == nil {
		return nil, newParseError("cannot parse authority from " + strconv.Quote(original))
	}
	host := strings.ToLower(m["host"])
	port := 0
	if p := m["port"]; p != "" {
		n, err := strconv.Atoi(p)
		if err != nil {
			return nil, newParseError("invalid port in " + strconv.Quote(original))
		}
		port = n
	}
	if port != 0 && defaultPorts[scheme] == port {
		port = 0
	}

	path, query, fragment := splitPathQueryFragment(m["rest"])
	segments := pathSegments(path)

	return &Identifier{
		Original:     original,
		Scheme:       scheme,
		Host:         host,
		Port:         port,
		Path:         "/" + strings.Join(segments, "/"),
		PathSegments: segments,
		Query:        query,
		QueryParams:  parseQuery(query),
		Fragment:     fragment,
		Kind:         KindURL,
	}, nil
}

func splitPathQueryFragment(rest string) (path, query, fragment string) {
	path = rest
	if i := strings.Index(path, "#"); i >= 0 {
		fragment = path[i+1:]
		path = path[:i]
	}
	if i := strings.Index(path, "?"); i >= 0 {
		query = path[i+1:]
		path = path[:i]
	}
	return
}

// pathSegments applies lightweight RFC 3986 §5.2.4 dot-segment normalization
// and drops empty segments from leading/trailing/duplicate slashes.
func pathSegments(path string) []string {
	if path == "" || path == "/" {
		return []string{}
	}
	path = strings.TrimPrefix(path, "/")
	raw := strings.Split(path, "/")
	out := make([]string, 0, len(raw))
	for _, seg := range raw {
		switch seg {
		case "", ".":
			continue
		case "..":
			if len(out) > 0 {
				out = out[:len(out)-1]
			}
		default:
			out = append(out, seg)
		}
	}
	return out
}

func parseQuery(query string) *OrderedMap {
	out := NewOrderedMap()
	if query == "" {
		return out
	}
	for _, pair := range strings.Split(query, "&") {
		k, v, _ := strings.Cut(pair, "=")
		if k == "" {
			continue
		}
		out.Set(k, v)
	}
	return out
}

// matchNamed runs a named-group regex and returns a map of group name -> match.
// Returns nil when the input doesn't match.
func matchNamed(re *regexp.Regexp, s string) map[string]string {
	m := re.FindStringSubmatch(s)
	if m == nil {
		return nil
	}
	out := make(map[string]string, len(re.SubexpNames()))
	for i, name := range re.SubexpNames() {
		if name == "" {
			continue
		}
		out[name] = m[i]
	}
	return out
}
