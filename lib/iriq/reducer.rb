module Iriq
  # Reducers consume the Event stream emitted by Corpus#observe and update
  # the storage backend's materialized views. Each Reducer is a callable
  # that takes (event, storage) and applies the appropriate storage
  # operation; non-applicable events are no-ops via the EVENT_TYPES gate.
  #
  # Adding a new metric is: define a new Event subtype, write a Reducer that
  # handles it, register it in DEFAULTS — no other module changes.
  module Reducer
    # Each entry: { event_class => [lambda(event, storage) -> result] }.
    # Lambdas may return the result of the underlying storage call so
    # callers (Corpus#observe) can pick up the cluster they need to return.
    DEFAULTS = {
      Event::HostSeen        => [->(e, s) { s.increment_host(e.host) }],
      Event::PathLengthSeen  => [->(e, s) { s.increment_path_length(e.length) }],
      Event::RawShapeSeen    => [->(e, s) { s.increment_raw_shape(e.shape) }],
      Event::FingerprintSeen => [->(e, s) { s.increment_fingerprint(e.shape) }],
      Event::PositionSeen    => [->(e, s) { s.observe_position(e.position, e.value, e.type) }],
      Event::ClusterAddition => [->(e, s) { s.add_to_cluster(e.key, e.host, e.scheme, e.shape, e.identifier) }],
    }.freeze

    module_function

    # Apply the event to the storage via all Reducers registered for its
    # type. Returns the last non-nil reducer result — used by Corpus#observe
    # to pick up the Cluster created/updated by Event::ClusterAddition.
    def apply(event, storage, reducers: DEFAULTS)
      results = reducers.fetch(event.class, [])
      result  = nil
      results.each do |r|
        rv = r.call(event, storage)
        result = rv unless rv.nil?
      end
      result
    end
  end
end
