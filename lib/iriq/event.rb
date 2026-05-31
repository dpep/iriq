module Iriq
  # Events are the atomic observation-time facts emitted by Corpus#observe
  # before any state changes. A single observe(iri) call emits a small
  # ordered list of Events; Reducers consume that list to update materialized
  # views (host counts, position stats, clusters, etc.).
  #
  # Today the event list is transient — built fresh per observe(), applied,
  # and discarded. The shape is in place so a future commit can persist the
  # log and replay it to re-derive materialized views without re-feeding
  # source IRIs (the "re-runnable inference" win from ROADMAP.md).
  #
  # Each Event is a Struct so callers can pattern-match on type and access
  # fields positionally or by name.
  module Event
    HostSeen        = Struct.new(:host)
    PathLengthSeen  = Struct.new(:length)
    RawShapeSeen    = Struct.new(:shape)
    FingerprintSeen = Struct.new(:shape)
    PositionSeen    = Struct.new(:position, :value, :type)
    ClusterAddition = Struct.new(:key, :host, :scheme, :shape, :identifier)
  end
end
