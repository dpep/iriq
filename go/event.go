package iriq

// Event is the marker interface for atomic observation-time facts emitted
// by Corpus.EventsFor. A single Observe(iri) call emits an ordered list of
// Events; Reducers consume the list to update the storage backend's
// materialized views.
//
// Today the event list is transient — built fresh per Observe, applied
// once, discarded. A future commit can persist the log and replay it to
// re-derive materialized views without re-feeding source IRIs (the
// re-runnable inference win from ROADMAP.md).
//
// Each concrete event embeds nothing; the EventKind method is the
// discriminator.
type Event interface {
	EventKind() string
}

// EventHostSeen marks "this host was observed once".
type EventHostSeen struct{ Host string }

func (EventHostSeen) EventKind() string { return "host_seen" }

// EventPathLengthSeen marks "an IRI with this path length was observed".
type EventPathLengthSeen struct{ Length int }

func (EventPathLengthSeen) EventKind() string { return "path_length_seen" }

// EventRawShapeSeen marks "this raw (untyped) shape was observed".
type EventRawShapeSeen struct{ Shape string }

func (EventRawShapeSeen) EventKind() string { return "raw_shape_seen" }

// EventFingerprintSeen marks "this hinted shape fingerprint was observed".
type EventFingerprintSeen struct{ Shape string }

func (EventFingerprintSeen) EventKind() string { return "fingerprint_seen" }

// EventPositionSeen marks "Position P saw value V (lexically typed T)".
type EventPositionSeen struct {
	Position Position
	Value    string
	Type     SegmentType
}

func (EventPositionSeen) EventKind() string { return "position_seen" }

// EventClusterAddition marks "Identifier was added to cluster Key".
type EventClusterAddition struct {
	Key        string
	Host       string
	Scheme     string
	Shape      string
	Identifier *Identifier
}

func (EventClusterAddition) EventKind() string { return "cluster_addition" }
