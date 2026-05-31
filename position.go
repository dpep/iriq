package iriq

import "fmt"

// PositionScope distinguishes path-segment positions from query-parameter
// positions. Marshaled as a lowercase string for JSON / SQLite parity with
// the Ruby side.
type PositionScope string

const (
	ScopePath  PositionScope = "path"
	ScopeQuery PositionScope = "query"
)

// Position is a typed slot in a host's URL structure.
//
// Two observations occupy the same Position when (Host, Scope, Locator)
// match exactly. Position is the keying type used by Storage for frequency
// tables and by Cluster for per-slot inference.
//
//   Host    — the EFFECTIVE host per Corpus.host_strategy. Observations of
//             api.foo.com and app.foo.com under :registrable share the same
//             Position. The original host stays on the Identifier.
//   Scope   — path or query.
//   Locator — for path, the typed prefix built up to this slot, e.g.
//             "/orgs/{opaque_id}/users" for the integer slot in
//             /orgs/abc/users/123. (Variable segments render as their hint
//             or display-type, so the prefix groups across observations
//             regardless of specific IDs seen.)
//           — for query, the ?key= parameter name.
//
// Position is a comparable struct so it works as a map key directly.
type Position struct {
	Host    string
	Scope   PositionScope
	Locator string
}

// PathPosition is a small constructor for the common path-scope case.
func PathPosition(host, prefix string) Position {
	return Position{Host: host, Scope: ScopePath, Locator: prefix}
}

// QueryPosition is the constructor for query-scope positions.
func QueryPosition(host, name string) Position {
	return Position{Host: host, Scope: ScopeQuery, Locator: name}
}

func (p Position) IsPath() bool  { return p.Scope == ScopePath }
func (p Position) IsQuery() bool { return p.Scope == ScopeQuery }

func (p Position) String() string {
	return fmt.Sprintf("Position(%q, %s, %q)", p.Host, p.Scope, p.Locator)
}
