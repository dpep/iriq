module Iriq
  # A group of identifiers that share a host + shape key. Tracks examples and
  # per-position segment statistics so callers can ask which positions are
  # actually stable in practice (e.g. /users/ always literal, /{integer}
  # always variable).
  class Cluster
    attr_reader :key, :host, :scheme, :shape, :examples, :count, :param_stats, :max_values

    MAX_EXAMPLES = 10

    # Share of date-typed observations required before the corpus promotes
    # a param to :date. 8-digit IDs in the 1900..2100 range look like
    # YYYYMMDD by accident — without quorum we'd canonicalize random IDs.
    DATE_CONFIDENCE_THRESHOLD = 0.8

    # `:number` umbrella thresholds. Promote a position to :number when
    # the combined :integer + :float observations dominate (≥ majority)
    # AND neither subtype alone hits the strong threshold (we have a clear
    # numeric pattern but it isn't purely ints or purely floats).
    NUMBER_CONFIDENCE_THRESHOLD = 0.8
    NUMBER_SUBTYPE_THRESHOLD    = 0.8

    # `:enum` thresholds. Promote a param to :enum when the corpus has seen
    # enough samples to trust the bound, the value set is small, each value
    # appears more than once (rules out singletons), and the tracked values
    # account for nearly all observations (lets a few stragglers through).
    ENUM_MIN_OBSERVATIONS = 20
    ENUM_MAX_CARDINALITY  = 10
    ENUM_MIN_VALUE_COUNT  = 2
    ENUM_MIN_COVERAGE     = 0.95

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
    #   { name: "page", count: N, type: :integer, cardinality: K, presence: 0.83 }
    # presence is count / @count — the fraction of observations that had
    # this param.
    def param_summary
      return [] if @param_stats.empty?

      @param_stats.map { |name, _stats|
        stats = @param_stats[name]
        type  = param_type(name)
        row   = {
          name:        name,
          count:       stats.total,
          type:        type,
          cardinality: stats.cardinality,
          presence:    @count.positive? ? stats.total.to_f / @count : 0.0,
        }
        row[:values] = enum_values(stats) if type == :enum
        row
      }.sort_by { |row| [-row[:count], row[:name]] }
    end

    # Returns the type the corpus is confident enough to call this param.
    # Equals stats.dominant_type when the dominant type isn't :date; when
    # :date is dominant but below DATE_CONFIDENCE_THRESHOLD, falls back to
    # the most-common non-date type (or :literal if none exists). Shared
    # by Cluster#param_summary and Corpus#inferred_param_type so both views
    # agree on what the corpus "thinks" about a param.
    def param_type(name)
      stats = @param_stats[name]
      return nil unless stats
      return nil if stats.total.zero?

      # :enum check first — bounded set of repeated values trumps the
      # underlying value type. We want `?status=active` to surface as :enum
      # (with the value list) rather than :literal even though each value
      # individually classifies as a literal.
      return :enum if enum?(stats)

      type = stats.dominant_type

      # :date gate — demote when there isn't enough date-typed quorum.
      if type == :date
        date_frac = stats.type_counts[:date].to_f / stats.total
        return type if date_frac >= DATE_CONFIDENCE_THRESHOLD

        return dominant_excluding(stats, :date) || :literal
      end

      # :number umbrella — promote when ints + floats together dominate
      # but neither alone is the clear winner.
      if type == :integer || type == :float
        int_frac   = stats.type_counts[:integer].to_f / stats.total
        float_frac = stats.type_counts[:float].to_f / stats.total
        if int_frac < NUMBER_SUBTYPE_THRESHOLD &&
           float_frac < NUMBER_SUBTYPE_THRESHOLD &&
           (int_frac + float_frac) >= NUMBER_CONFIDENCE_THRESHOLD
          return :number
        end
      end

      type
    end

    # True when stats shows a bounded set of repeated values worth treating
    # as an enum. See ENUM_* constants at the top of this class.
    def enum?(stats)
      return false if stats.total < ENUM_MIN_OBSERVATIONS
      return false if stats.cardinality.zero? || stats.cardinality > ENUM_MAX_CARDINALITY
      return false if stats.value_counts.any? { |_, n| n < ENUM_MIN_VALUE_COUNT }

      coverage = stats.value_counts.values.sum.to_f / stats.total
      coverage >= ENUM_MIN_COVERAGE
    end

    # Distinct values tracked for this param, ordered by descending count
    # (lex tie-break). Returned alongside :enum-typed rows in param_summary
    # so verbose/explain consumers can render the value set.
    def enum_values(stats)
      stats.value_counts.sort_by { |v, n| [-n, v] }.map(&:first)
    end

    # Most common type in stats.type_counts excluding `skip` — lex tie-break
    # so the choice is deterministic across runtimes.
    def dominant_excluding(stats, skip)
      best = nil
      best_count = -1
      stats.type_counts.each do |t, n|
        next if t == skip
        if n > best_count || (n == best_count && t.to_s < best.to_s)
          best = t
          best_count = n
        end
      end
      best
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
    # own shape from the NSS value. `host:` overrides iri.host — used by
    # Corpus when host_strategy collapses subdomains or ignores the host.
    def self.key_for(iri, classifier:, shape: nil, host: nil)
      if iri.urn?
        ns, value = (iri.nss || "").split(":", 2)
        derived = value ? urn_value_shape(ns, value, classifier) : nil
        key     = "urn:#{ns}:#{derived}"
        [key, nil, "urn", key]
      else
        shape ||= PathShape.new(classifier: classifier).for(iri.path_segments)
        effective_host = host.nil? ? iri.host : host
        key = "#{iri.scheme}://#{effective_host}#{shape}"
        [key, effective_host, iri.scheme, shape]
      end
    end

    def self.urn_value_shape(ns, value, classifier)
      entry = SegmentHints.derive([ns, value], classifier).last
      return entry[:value] unless entry[:variable]

      "{#{entry[:hint] || entry[:type]}}"
    end
  end
end
