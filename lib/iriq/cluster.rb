module Iriq
  # A group of identifiers that share a host + shape key. Tracks examples and
  # per-position segment statistics so callers can ask which positions are
  # actually stable in practice (e.g. /users/ always literal, /{integer}
  # always variable).
  class Cluster
    attr_reader :key, :host, :scheme, :shape, :examples, :count, :param_stats, :max_values

    # Structured Shape lazily derived from the first observed example —
    # Iriq::Shape, or nil if no examples are present yet. Cached after the
    # first call.
    def shape_object(classifier: SegmentClassifier::DEFAULT)
      return @shape_object if @shape_object
      return nil if @examples.empty?

      @shape_object = Shape.from_segments(@examples.first.path_segments, classifier: classifier)
    end

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

    # Param classification is a confidence ladder: constant → string → enum.
    # A param with a single observed value is a constant (rendered as-is); one
    # that varies but isn't yet a trustworthy enum is :string (a generic
    # placeholder); a bounded, well-supported value set is :enum.
    #
    # `:enum` thresholds. Promote a param to :enum when the corpus has seen
    # enough samples to trust the bound (ENUM_MIN_OBSERVATIONS), the *established*
    # values — those seen at least ENUM_MIN_VALUE_COUNT times — are few
    # (ENUM_MAX_CARDINALITY) and cover nearly all observations
    # (ENUM_MIN_COVERAGE). Rare one-off values are stragglers, not
    # disqualifiers: this is what keeps a single brand-new value from knocking
    # an established enum back down (the observe-before-normalize case).
    ENUM_MIN_OBSERVATIONS = 20
    ENUM_MAX_CARDINALITY  = 10
    ENUM_MIN_VALUE_COUNT  = 3
    ENUM_MIN_COVERAGE     = 0.9
    # An enum is a bounded *set*: a single repeated value is a constant, not an
    # enum, so it takes at least two established members to qualify.
    ENUM_MIN_MEMBERS      = 2

    # `:string` — a param that has taken on 2+ distinct non-typed values but
    # isn't (yet) a confident enum. The intermediate rung: we know it varies
    # and looks like free-form text, but haven't earned the bounded-set claim.
    STRING_MIN_DISTINCT = 2

    # Confidence smoothing constant. confidence = total / (total + K): a
    # monotone curve that is 0.5 at K observations and asymptotes to 1.0. The
    # type names our guess; this number says how much evidence backs it.
    CONFIDENCE_SMOOTHING = 15

    def initialize(key:, host:, scheme:, shape:, max_values: PositionStats::DEFAULT_MAX_VALUES)
      @key            = key
      @host           = host
      @scheme         = scheme
      @shape          = shape
      @shape_object   = nil
      @examples       = []
      @example_keys   = Set.new
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
      if @examples.size < MAX_EXAMPLES
        canon = identifier.canonical
        @examples << identifier unless @example_keys.include?(canon)
        @example_keys << canon
      end

      identifier.path_segments.each_with_index do |seg, i|
        @segment_counts[i] ||= Hash.new(0)
        @segment_counts[i][seg] += 1
      end

      return unless identifier.query_params
      identifier.query_params.each do |name, value|
        stats = @param_stats[name] ||= PositionStats.new(max_values: @max_values)
        value_s = value.to_s
        stats.observe(value_s, classifier.classify(value_s))
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
    #   { name: "page", count: N, type: :integer, confidence: 0.83,
    #     cardinality: K, presence: 0.83 }
    # confidence is how much evidence backs the type (see param_confidence);
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
          confidence:  param_confidence(stats),
          cardinality: stats.cardinality,
          presence:    @count.positive? ? stats.total.to_f / @count : 0.0,
        }
        row[:values] = enum_values(stats) if type == :enum
        # Verbose value distribution — fractions over tracked occurrences.
        # Boolean and enum positions get the per-value breakdown (e.g.
        # `true: 0.97, false: 0.03`). Number positions get the int-vs-float
        # split via :subtype_distribution.
        if type == :boolean || type == :enum
          row[:value_distribution] = value_distribution(stats)
        end
        if type == :number
          row[:subtype_distribution] = subtype_distribution(stats, %i[integer float])
        end
        # :file kind breakdown — derived from tracked value_counts at
        # summary time. Best-effort: only reflects observations within
        # the value-tracking cap.
        if type == :file
          row[:kind_distribution] = file_kind_distribution(stats)
        end
        if stats.numeric_count.positive?
          row[:min] = stats.numeric_min
          row[:max] = stats.numeric_max
          row[:avg] = stats.numeric_avg
        end
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

      type = stats.dominant_type

      # :year takes priority over :enum for numeric range columns —
      # a "years 2020..2026" position is more useful described as a
      # ranged year than as an enum of those specific values.
      return :year if year_position?(type, stats)
      # :http_status — 3-digit ints clustered in 100..599 are almost
      # certainly HTTP statuses. Same shape as :year (range check) but
      # tighter window. Useful for `?status=...` or path positions that
      # echo a status code.
      return :http_status if http_status_position?(type, stats)

      # :enum check — bounded set of repeated values trumps the underlying
      # value type. `?status=active|draft|archived` surfaces as :enum
      # (with the value list) rather than :literal even though each value
      # individually classifies as a literal. Skip the override when the
      # dominant type is already specific (`:boolean` carries more meaning
      # than a 2-value enum).
      return :enum if enum?(stats) && type != :boolean

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

      # Param-name fallback — `?phone=...` overrides a generic literal
      # type with `:phone` when the value's shape was too weak to detect
      # on its own. Only fires for overridable types (literal/opaque_id/slug).
      if (hint = SegmentClassifier.param_name_hint(name, type))
        return hint
      end

      # :string rung — a literal-valued param that has taken on more than one
      # distinct value varies, so it's a placeholder, not a fixed constant.
      # Below the enum bar (checked above), so we claim only "free-form text".
      return :string if type == :literal && stats.cardinality >= STRING_MIN_DISTINCT

      type
    end

    YEAR_RANGE              = 1900..2100
    YEAR_MIN_OBSERVATIONS   = 5
    YEAR_MIN_DISTINCT       = 2
    YEAR_MAX_DISTINCT       = 150

    def year_position?(type, stats)
      return false unless type == :integer
      return false if stats.numeric_count.zero?
      return false if stats.cardinality < YEAR_MIN_DISTINCT
      return false if stats.cardinality > YEAR_MAX_DISTINCT
      return false if stats.total < YEAR_MIN_OBSERVATIONS

      YEAR_RANGE.cover?(stats.numeric_min) && YEAR_RANGE.cover?(stats.numeric_max)
    end

    HTTP_STATUS_RANGE            = 100..599
    HTTP_STATUS_MIN_OBSERVATIONS = 5
    HTTP_STATUS_MIN_DISTINCT     = 2
    HTTP_STATUS_MAX_DISTINCT     = 30

    def http_status_position?(type, stats)
      return false unless type == :integer
      return false if stats.numeric_count.zero?
      return false if stats.cardinality < HTTP_STATUS_MIN_DISTINCT
      return false if stats.cardinality > HTTP_STATUS_MAX_DISTINCT
      return false if stats.total < HTTP_STATUS_MIN_OBSERVATIONS

      HTTP_STATUS_RANGE.cover?(stats.numeric_min) && HTTP_STATUS_RANGE.cover?(stats.numeric_max)
    end

    # True when stats shows a bounded set of repeated values worth treating
    # as an enum. Built around the *established* members (values seen at least
    # ENUM_MIN_VALUE_COUNT times) so a stray one-off value is a straggler, not
    # a disqualifier. See ENUM_* constants at the top of this class.
    def enum?(stats)
      return false if stats.total < ENUM_MIN_OBSERVATIONS

      established = established_values(stats)
      return false unless established.size.between?(ENUM_MIN_MEMBERS, ENUM_MAX_CARDINALITY)

      coverage = established.values.sum.to_f / stats.total
      coverage >= ENUM_MIN_COVERAGE
    end

    # Values seen often enough to count as real members of the set (vs noise).
    def established_values(stats)
      stats.value_counts.select { |_, n| n >= ENUM_MIN_VALUE_COUNT }
    end

    # Confidence that the assigned type is right, given how much evidence backs
    # it. Monotone in observation count; 0.5 at CONFIDENCE_SMOOTHING, → 1.0.
    def param_confidence(stats)
      return 0.0 if stats.total.zero?

      (stats.total.to_f / (stats.total + CONFIDENCE_SMOOTHING)).round(2)
    end

    # The enum's member values — the established ones (seen enough to be real),
    # ordered by descending count (lex tie-break). Stragglers are excluded so
    # the advertised set is what the corpus is actually confident about.
    def enum_values(stats)
      established_values(stats).sort_by { |v, n| [-n, v] }.map(&:first)
    end

    # value_distribution returns the fraction of total observations each
    # tracked value represents, ordered by descending count then lex. Used
    # by param_summary for :boolean and :enum positions so callers can
    # render "true 97%, false 3%"-style breakdowns.
    def value_distribution(stats)
      return {} if stats.total.zero?

      stats.value_counts.sort_by { |v, n| [-n, v] }.to_h.transform_values do |n|
        (n.to_f / stats.total).round(4)
      end
    end

    # subtype_distribution slices type_counts to a specific subset and
    # returns the fraction each subtype represents. Used for the :number
    # umbrella to expose the int-vs-float split.
    def subtype_distribution(stats, subtypes)
      return {} if stats.total.zero?

      subtypes.each_with_object({}) do |t, out|
        n = stats.type_counts[t] || 0
        out[t] = (n.to_f / stats.total).round(4) if n.positive?
      end
    end

    # file_kind_distribution buckets tracked values by file kind and
    # returns the fraction each kind represents over tracked observations.
    # `:unknown` covers values that classified as :file but whose extension
    # isn't in the kind allowlist (shouldn't normally happen since the
    # classifier already gates on the kind map). Sums to ≤ 1.0 since
    # value_counts caps at PositionStats::DEFAULT_MAX_VALUES.
    def file_kind_distribution(stats)
      return {} if stats.value_counts.empty?

      total = stats.value_counts.values.sum
      return {} if total.zero?

      kinds = Hash.new(0)
      stats.value_counts.each do |value, n|
        kind = SegmentClassifier.file_kind(value) || :unknown
        kinds[kind] += n
      end
      kinds.sort_by { |k, n| [-n, k.to_s] }.to_h.transform_values do |n|
        (n.to_f / total).round(4)
      end
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
      examples = h["examples"].map { |s| Parser.parse(s) }
      cluster.instance_variable_set(:@examples, examples)
      cluster.instance_variable_set(:@example_keys, examples.map(&:canonical).to_set)
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
