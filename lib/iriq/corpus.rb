require "json"

module Iriq
  # Streaming-friendly observer over a (potentially unbounded) corpus of IRIs.
  # Maintains rolling aggregates and per-(host, prefix) frequency stats so
  # that classification can improve as more data flows in.
  #
  # The deterministic, single-IRI API (Iriq.normalize/explain) is unchanged —
  # Corpus#normalize and Corpus#explain are the corpus-informed variants.
  class Corpus
    # Type-based: position is "mostly variable" (UUIDs/integers/etc.).
    VARIABLE_DOMINANCE_THRESHOLD = 0.8

    # Cardinality-based: position has mostly distinct literal values, so the
    # literal "type" is misleading — it's really a variable slot. We trigger
    # on either:
    #   - very high cardinality fraction (most observations are singletons), OR
    #   - moderate cardinality fraction AND high absolute distinct count
    # The second branch catches realistic streams where popular outliers
    # bring the frac down but the long tail is clearly variable.
    LITERAL_UNIQUENESS_THRESHOLD          = 0.8
    LITERAL_UNIQUENESS_MODERATE_THRESHOLD = 0.5
    MIN_CARDINALITY_FOR_INFERENCE         = 20

    # Don't apply corpus heuristics until we have at least this many
    # observations at a position — too easy to be wrong with tiny samples.
    MIN_OBSERVATIONS_FOR_INFERENCE = 5

    # Value-fraction at or above which a literal is considered the stable
    # occupant of its position.
    STABLE_LITERAL_THRESHOLD = 0.5

    # Within a high-cardinality literal position (mostly singletons), a
    # specific value qualifies as a "popular outlier" — and gets preserved
    # as :stable_literal instead of being lumped into :corpus_inferred_variable
    # — when its count is at least POPULAR_MIN_COUNT and its frequency is at
    # least POPULAR_BASELINE_MULTIPLE × the uniform baseline (1/cardinality).
    POPULAR_MIN_COUNT         = 5
    POPULAR_BASELINE_MULTIPLE = 3

    attr_reader :host_counts, :path_length_counts, :raw_shape_counts,
                :fingerprint_counts, :position_stats

    def initialize(classifier: SegmentClassifier.new,
                   max_values_per_position: PositionStats::DEFAULT_MAX_VALUES)
      @classifier              = classifier
      @max_values_per_position = max_values_per_position
      @host_counts             = Hash.new(0)
      @path_length_counts      = Hash.new(0)
      @raw_shape_counts        = Hash.new(0)
      @fingerprint_counts      = Hash.new(0)
      @position_stats          = {}
      @clusterer               = Clusterer.new(classifier: classifier)
    end

    # Observe a single IRI. Returns an Observation.
    def observe(input)
      iri = coerce(input)
      hinted_entries = SegmentHints.derive(iri.path_segments, @classifier)
      record_aggregates(iri, hinted_entries)
      hinted_shape = PathShape.new(classifier: @classifier, hints: true).from_entries(hinted_entries)
      cluster = @clusterer.add(iri, shape: hinted_shape)
      Observation.new(corpus: self, identifier: iri, cluster: cluster)
    end

    # Corpus-informed normalization. Falls back to mechanical normalization
    # when the corpus has no signal for a position.
    def normalize(input)
      iri = coerce(input)
      return Normalizer.normalize_identifier(iri) if iri.urn? || iri.path_segments.empty?

      tokens = annotate_segments(iri).map { |entry| corpus_token(entry) }
      out = +""
      out << "#{iri.scheme}://" if iri.scheme
      out << iri.host if iri.host
      out << ":#{iri.port}" if iri.port
      out << "/" << tokens.join("/")
      out
    end

    # Per-segment explanation with corpus-informed `classification`.
    # Returns an array of entries shaped like the Explanation rows plus
    # `classification:` ∈ :stable_literal, :variable_identifier,
    # :rare_literal, :ambiguous, :corpus_inferred_variable.
    def explain(input)
      iri = coerce(input)
      annotate_segments(iri).map do |entry|
        entry.reject { |k, _| k == :prefix }
      end
    end

    def clusters
      @clusterer.clusters
    end

    def size
      @clusterer.size
    end

    # Stats for a given (host, prefix_shape) — useful for tests and
    # debugging. Returns nil if nothing has been observed there.
    def stats_for(host, prefix)
      @position_stats[[host, prefix]]
    end

    private

    def coerce(input)
      input.is_a?(Identifier) ? input : Parser.parse(input)
    end

    def record_aggregates(iri, hinted_entries)
      @host_counts[iri.host] += 1 if iri.host
      @path_length_counts[iri.path_segments.size] += 1

      raw = PathShape.new(classifier: @classifier, hints: false).from_entries(hinted_entries)
      fp  = PathShape.new(classifier: @classifier, hints: true).from_entries(hinted_entries)
      @raw_shape_counts[raw] += 1
      @fingerprint_counts[fp] += 1

      record_position_stats(iri, hinted_entries)
    end

    def record_position_stats(iri, hinted_entries)
      prefix = ""
      hinted_entries.each do |entry|
        key   = [iri.host, prefix]
        stats = @position_stats[key] ||= PositionStats.new(max_values: @max_values_per_position)
        stats.observe(entry[:value], entry[:type])
        prefix = "#{prefix}/#{placeholder(entry)}"
      end
    end

    # Walks the IRI's segments and returns hint-derived entries enriched with
    # the (host, prefix) PositionStats reference and a :classification symbol.
    def annotate_segments(iri)
      hinted = SegmentHints.derive(iri.path_segments, @classifier)
      prefix = ""
      hinted.map do |entry|
        stats = @position_stats[[iri.host, prefix]]
        out = entry.merge(
          prefix:         prefix,
          classification: classify(entry, stats),
        )
        prefix = "#{prefix}/#{placeholder(entry)}"
        out
      end
    end

    def placeholder(entry)
      return entry[:value] unless entry[:variable]

      "{#{entry[:hint] || entry[:type]}}"
    end

    def classify(entry, stats)
      variable = entry[:variable]

      return variable ? :variable_identifier : :ambiguous if stats.nil? || stats.total.zero?
      return :variable_identifier if variable

      value            = entry[:value]
      total            = stats.total
      variable_frac    = stats.variable_fraction(@classifier)
      cardinality_frac = stats.cardinality.to_f / total
      enough_data      = total >= MIN_OBSERVATIONS_FOR_INFERENCE
      value_frac       = stats.value_fraction(value)

      if enough_data && variable_frac >= VARIABLE_DOMINANCE_THRESHOLD
        # Position is dominated by variable types (UUIDs, integers, etc.).
        # A literal here is a special-case outlier (e.g. /users/me).
        stats.value_counts.key?(value) ? :rare_literal : :ambiguous
      elsif value_frac >= STABLE_LITERAL_THRESHOLD
        # This specific value dominates — preserve it regardless of how
        # diverse the rest of the position is.
        :stable_literal
      elsif enough_data && high_cardinality_literal_position?(stats, cardinality_frac)
        # High-cardinality literal position — usually a variable slot, but
        # recognize values that dramatically exceed the uniform baseline as
        # "popular outliers" (e.g. /workspaces/mainspace surviving in a slot
        # full of one-shot user-created workspace names).
        popular_outlier?(stats, value) ? :stable_literal : :corpus_inferred_variable
      elsif stats.cardinality == 1
        :stable_literal
      elsif stats.value_counts.key?(value)
        :rare_literal
      else
        :ambiguous
      end
    end

    def high_cardinality_literal_position?(stats, cardinality_frac)
      return true if cardinality_frac >= LITERAL_UNIQUENESS_THRESHOLD

      cardinality_frac >= LITERAL_UNIQUENESS_MODERATE_THRESHOLD &&
        stats.cardinality >= MIN_CARDINALITY_FOR_INFERENCE
    end

    def popular_outlier?(stats, value)
      count = stats.value_counts[value] || 0
      return false if count < POPULAR_MIN_COUNT

      baseline = 1.0 / stats.cardinality
      stats.value_fraction(value) >= POPULAR_BASELINE_MULTIPLE * baseline
    end

    def corpus_token(entry)
      case entry[:classification]
      when :variable_identifier, :corpus_inferred_variable
        placeholder_for_variable(entry)
      else
        entry[:value]
      end
    end

    def placeholder_for_variable(entry)
      return "{#{entry[:hint] || entry[:type]}}" if entry[:variable]

      # corpus-inferred variable: classifier said literal, corpus says
      # otherwise. Derive a hint from the prefix's last literal segment if
      # we can.
      last_literal = entry[:prefix].split("/").reject(&:empty?).reject { |s| s.start_with?("{") }.last
      base = last_literal ? Inflector.singularize(last_literal) : nil
      base ? "{#{base}}" : "{value}"
    end

    public

    def dump
      {
        "host_counts"             => @host_counts,
        "path_length_counts"      => @path_length_counts.transform_keys(&:to_s),
        "raw_shape_counts"        => @raw_shape_counts,
        "fingerprint_counts"      => @fingerprint_counts,
        "max_values_per_position" => @max_values_per_position,
        "position_stats"          => @position_stats.map { |(host, prefix), s| [host, prefix, s.dump] },
        "clusterer"               => @clusterer.dump,
      }
    end

    def save(path)
      tmp = "#{path}.tmp"
      File.write(tmp, JSON.generate(dump))
      File.rename(tmp, path)
    end

    def self.from_dump(h, classifier: SegmentClassifier.new)
      c = new(
        classifier: classifier,
        max_values_per_position: h.fetch("max_values_per_position", PositionStats::DEFAULT_MAX_VALUES),
      )
      c.instance_variable_set(:@host_counts,        Hash.new(0).merge(h["host_counts"]))
      c.instance_variable_set(:@path_length_counts, Hash.new(0).merge(h["path_length_counts"].transform_keys(&:to_i)))
      c.instance_variable_set(:@raw_shape_counts,   Hash.new(0).merge(h["raw_shape_counts"]))
      c.instance_variable_set(:@fingerprint_counts, Hash.new(0).merge(h["fingerprint_counts"]))
      stats = h["position_stats"].each_with_object({}) do |(host, prefix, sdump), acc|
        acc[[host, prefix]] = PositionStats.from_dump(sdump)
      end
      c.instance_variable_set(:@position_stats, stats)
      c.instance_variable_set(:@clusterer, Clusterer.from_dump(h["clusterer"], classifier: classifier))
      c
    end

    def self.load(path, classifier: SegmentClassifier.new)
      from_dump(JSON.parse(File.read(path)), classifier: classifier)
    end
  end
end
