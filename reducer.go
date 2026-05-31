package iriq

// Reducer consumes a single Event and applies the corresponding mutation
// to the storage backend. Reducers are independent: adding a new
// materialized view is "define a new Event type, write a Reducer that
// handles it, register it via DefaultReducers" — no other module changes.
//
// The result is the (optional) value the reducer wants to surface to the
// caller — Corpus.Observe uses it to pick up the *Cluster created by
// EventClusterAddition.
type Reducer func(e Event, s Storage) any

// DefaultReducers maps each Event type's EventKind() to the registered
// reducer chain. Build via init() so the table is constructed once.
var DefaultReducers = map[string][]Reducer{
	(EventHostSeen{}).EventKind(): {func(e Event, s Storage) any {
		s.IncrementHost(e.(EventHostSeen).Host)
		return nil
	}},
	(EventPathLengthSeen{}).EventKind(): {func(e Event, s Storage) any {
		s.IncrementPathLength(e.(EventPathLengthSeen).Length)
		return nil
	}},
	(EventRawShapeSeen{}).EventKind(): {func(e Event, s Storage) any {
		s.IncrementRawShape(e.(EventRawShapeSeen).Shape)
		return nil
	}},
	(EventFingerprintSeen{}).EventKind(): {func(e Event, s Storage) any {
		s.IncrementFingerprint(e.(EventFingerprintSeen).Shape)
		return nil
	}},
	(EventPositionSeen{}).EventKind(): {func(e Event, s Storage) any {
		ev := e.(EventPositionSeen)
		s.ObservePosition(ev.Position, ev.Value, ev.Type)
		return nil
	}},
	(EventClusterAddition{}).EventKind(): {func(e Event, s Storage) any {
		ev := e.(EventClusterAddition)
		return s.AddToCluster(ev.Key, ev.Host, ev.Scheme, ev.Shape, ev.Identifier)
	}},
}

// ApplyEvent runs the registered reducers for the event's kind against
// the storage. Returns the last non-nil reducer result (used by
// Corpus.Observe to pick up the *Cluster from EventClusterAddition).
func ApplyEvent(e Event, s Storage) any {
	var result any
	for _, r := range DefaultReducers[e.EventKind()] {
		if rv := r(e, s); rv != nil {
			result = rv
		}
	}
	return result
}
