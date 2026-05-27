module Iriq
  # A group of identifiers that share a host + shape key. Tracks examples and
  # per-position segment statistics so callers can ask which positions are
  # actually stable in practice (e.g. /users/ always literal, /{integer_id}
  # always variable).
  class Cluster
    attr_reader :key, :host, :scheme, :shape, :examples, :count, :param_stats, :max_values

    MAX_EXAMPLES = 10

    def initialize(key:, host:, scheme:, shape:, max_values: PositionStats::DEFAULT_MAX_VALUES)
      @key            = key
      @host           = host
      @scheme         = scheme
      @shape          = shape
      @examples       = []
      @count          = 0
      @segment_counts = []
      @max_values     = max_values
      # Query-param stats keyed by param name. Each is a PositionStats — same
      # cardinality cap, same type-counts machinery, just indexed by ?key=
      # instead of by path position.
      @param_stats    = {}
    end

    def add(identifier, classifier: SegmentClassifier::DEFAULT)
      @count += 1
      @examples << identifier if @examples.size < MAX_EXAMPLES

      identifier.path_segments.each_with_index do |seg, i|
        @segment_counts[i] ||= Hash.new(0)
        @segment_counts[i][seg] += 1
      end

      return unless identifier.query_params
      identifier.query_params.each do |name, value|
        stats = @param_stats[name] ||= PositionStats.new(max_values: @max_values)
        stats.observe(value.to_s, classifier.classify(value.to_s))
      end
    end

    # Per-position summary:
    #   [
    #     { position: 0, stable: true,  values: { "users" => 3 } },
    #     { position: 1, stable: false, values: { "1" => 1, "2" => 1, "3" => 1 } },
    #   ]
    def segment_stats
      @segment_counts.each_with_index.map do |counts, i|
        {
          position: i,
          stable:   counts.size == 1,
          values:   counts.dup,
        }
      end
    end

    def to_h
      {
        key:      key,
        host:     host,
        scheme:   scheme,
        shape:    shape,
        count:    count,
        examples: examples.map(&:canonical),
        segments: segment_stats,
        params:   param_summary,
      }
    end

    # Per-param summary, ordered by descending presence. Each entry is:
    #   { name: "page", count: N, type: :integer_id, cardinality: K, presence: 0.83 }
    # presence is count / @count — the fraction of observations that had
    # this param.
    def param_summary
      return [] if @param_stats.empty?

      @param_stats.map { |name, stats|
        {
          name:        name,
          count:       stats.total,
          type:        stats.dominant_type,
          cardinality: stats.cardinality,
          presence:    @count.positive? ? stats.total.to_f / @count : 0.0,
        }
      }.sort_by { |row| [-row[:count], row[:name]] }
    end

    # JSON-friendly dump for persistence (distinct from #to_h which is a
    # display form). Examples are dumped as canonical strings and re-parsed
    # on load.
    def dump
      {
        "key"            => key,
        "host"           => host,
        "scheme"         => scheme,
        "shape"          => shape,
        "count"          => count,
        "examples"       => examples.map(&:canonical),
        "segment_counts" => @segment_counts.map { |h| h || {} },
        "param_stats"    => @param_stats.transform_values(&:dump),
      }
    end

    def self.from_dump(h, max_values: PositionStats::DEFAULT_MAX_VALUES)
      cluster = new(
        key: h["key"], host: h["host"], scheme: h["scheme"], shape: h["shape"],
        max_values: max_values,
      )
      cluster.instance_variable_set(:@count, h["count"])
      cluster.instance_variable_set(:@examples, h["examples"].map { |s| Parser.parse(s) })
      cluster.instance_variable_set(:@segment_counts, h["segment_counts"].map { |sub| Hash.new(0).merge(sub) })
      params = (h["param_stats"] || {}).transform_values { |sd| PositionStats.from_dump(sd) }
      cluster.instance_variable_set(:@param_stats, params)
      cluster
    end

    # Shared cluster-key derivation. Returns [key, host, scheme, shape] —
    # callers that already have a hinted shape can pass it in to skip the
    # recomputation; URN inputs ignore the override and always derive their
    # own shape from the NSS value.
    def self.key_for(iri, classifier:, shape: nil)
      if iri.urn?
        ns, value = (iri.nss || "").split(":", 2)
        derived = value ? urn_value_shape(ns, value, classifier) : nil
        key     = "urn:#{ns}:#{derived}"
        [key, nil, "urn", key]
      else
        shape ||= PathShape.new(classifier: classifier).for(iri.path_segments)
        key = "#{iri.scheme}://#{iri.host}#{shape}"
        [key, iri.host, iri.scheme, shape]
      end
    end

    def self.urn_value_shape(ns, value, classifier)
      entry = SegmentHints.derive([ns, value], classifier).last
      return entry[:value] unless entry[:variable]

      "{#{entry[:hint] || entry[:type]}}"
    end
  end
end
