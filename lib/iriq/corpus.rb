require "json"

module Iriq
  # Streaming-friendly observer over a (potentially unbounded) corpus of IRIs.
  # Maintains rolling aggregates and per-(host, prefix) frequency stats so
  # that classification can improve as more data flows in.
  #
  # The deterministic, single-IRI API (Iriq.normalize/explain) is unchanged —
  # Corpus#normalize and Corpus#explain are the corpus-informed variants.
  #
  # State lives in a Storage backend (Memory by default; Json or Sqlite when
  # opened against a file). The classification logic on top is identical
  # regardless of where the counters live.
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

    HOST_STRATEGIES = %i[full registrable none].freeze

    attr_reader :storage, :host_strategy

    def initialize(classifier: SegmentClassifier::DEFAULT,
                   max_values_per_position: PositionStats::DEFAULT_MAX_VALUES,
                   host_strategy: :full,
                   storage: nil)
      raise ArgumentError, "host_strategy must be one of #{HOST_STRATEGIES.inspect}" \
        unless HOST_STRATEGIES.include?(host_strategy)

      @classifier    = classifier
      @host_strategy = host_strategy
      @storage       = storage || Storage::Memory.new(
        classifier: classifier,
        max_values_per_position: max_values_per_position,
      )
    end

    # Open a corpus against `path`. File extension picks the backend:
    # `.db`/`.sqlite`/`.sqlite3` use SQLite (incremental writes); anything
    # else uses JSON.
    def self.open(path, classifier: SegmentClassifier::DEFAULT,
                        max_values_per_position: PositionStats::DEFAULT_MAX_VALUES,
                        host_strategy: :full)
      storage = Storage.open(path,
                             classifier: classifier,
                             max_values_per_position: max_values_per_position)
      new(classifier: classifier, storage: storage, host_strategy: host_strategy)
    end

    # Normalize the host for keying purposes. `:full` keeps the original
    # host; `:registrable` collapses subdomains via the inline-PSL heuristic
    # (api.foo.com + app.foo.com → foo.com); `:none` ignores host entirely
    # so clusters group across all hosts by shape alone.
    def effective_host(host)
      case @host_strategy
      when :registrable then RegistrableDomain.for(host)
      when :none        then ""
      else                   host
      end
    end

    # Observe a single IRI. Returns an Observation.
    def observe(input)
      iri = coerce(input)
      hinted_entries = SegmentHints.derive(iri.path_segments, @classifier)
      raw_shape    = PathShape.new(classifier: @classifier, hints: false).from_entries(hinted_entries)
      hinted_shape = PathShape.new(classifier: @classifier, hints: true).from_entries(hinted_entries)
      keying_host  = effective_host(iri.host)

      cluster = nil
      @storage.transaction do |s|
        s.increment_host(keying_host)
        s.increment_path_length(iri.path_segments.size)
        s.increment_raw_shape(raw_shape)
        s.increment_fingerprint(hinted_shape)

        prefix = ""
        hinted_entries.each do |entry|
          s.observe_position(Position.path(host: keying_host, prefix: prefix),
                             entry[:value], entry[:type])
          prefix = "#{prefix}/#{placeholder(entry)}"
        end

        key, host, scheme, shape = Cluster.key_for(iri, classifier: @classifier, shape: hinted_shape, host: keying_host)
        cluster = s.add_to_cluster(key, host, scheme, shape, iri)
      end

      Observation.new(corpus: self, identifier: iri, cluster: cluster)
    end

    # Corpus-informed normalization. Falls back to mechanical normalization
    # when the corpus has no signal for a position. Includes any observed
    # query params, rendered with corpus-informed types when the cluster has
    # tracked them.
    def normalize(input)
      iri = coerce(input)
      return Normalizer.normalize_identifier(iri) if iri.urn?

      tokens = annotate_segments(iri).map { |entry| corpus_token(entry) }
      out = +""
      out << "#{iri.scheme}://" if iri.scheme
      out << iri.host if iri.host
      out << ":#{iri.port}" if iri.port
      # Always emit a path. Empty path renders as "/" to match the mechanical
      # Iriq.normalize output and to anchor any trailing query string.
      out << "/" << tokens.join("/")
      out << "?" << render_query(iri) if iri.query_params && !iri.query_params.empty?
      out
    end

    # Inferred params for the cluster `input` would fall into. Returns the
    # same shape as Cluster#param_summary — useful for "what query params
    # might this URL accept?" tooling. Empty array if no cluster has been
    # observed for this shape yet.
    def params_for(input)
      iri = coerce(input)
      hinted_shape = PathShape.new(classifier: @classifier, hints: true)
                              .from_entries(SegmentHints.derive(iri.path_segments, @classifier))
      key, * = Cluster.key_for(iri, classifier: @classifier, shape: hinted_shape,
                               host: effective_host(iri.host))
      cluster = @storage.cluster_for(key)
      cluster ? cluster.param_summary : []
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

    def host_counts;        @storage.host_counts;        end
    def path_length_counts; @storage.path_length_counts; end
    def raw_shape_counts;   @storage.raw_shape_counts;   end
    def fingerprint_counts; @storage.fingerprint_counts; end

    # Iterates Position → PositionStats over all observed positions.
    # Used by inspection tooling; not part of the hot path.
    def each_position_stats(&block)
      @storage.each_position_stats(&block)
    end

    def clusters
      @storage.clusters
    end

    def size
      @storage.cluster_size
    end

    # Stats for a given (host, path-prefix) — useful for tests and
    # debugging. Returns nil if nothing has been observed there.
    # Accepts either a Position or (host, prefix) for ergonomics.
    def stats_for(host_or_position, prefix = nil)
      position = host_or_position.is_a?(Position) ? host_or_position : Position.path(host: host_or_position, prefix: prefix)
      @storage.position_stats(position)
    end

    # Persist the corpus.
    #
    #   save()           → flush the backend in place (JSON writes its file,
    #                      SQLite is already on disk).
    #   save(same_path)  → same as save() — idempotent for the backend's path.
    #   save(other_path) → export to other_path as JSON, regardless of the
    #                      live backend.
    def save(path = nil)
      backend_path = @storage.respond_to?(:path) ? @storage.path : nil
      if path.nil? || path == backend_path
        @storage.save
      else
        write_json_dump(path)
      end
    end

    def close
      @storage.close
    end

    # Wrap many observations in a single backend transaction. For SQLite this
    # turns thousands of fsyncs into one; for in-memory backends it's a
    # no-op. Use when ingesting a batch.
    def batch(&block)
      @storage.batch(&block)
    end

    private

    def coerce(input)
      input.is_a?(Identifier) ? input : Parser.parse(input)
    end

    def annotate_segments(iri)
      hinted = SegmentHints.derive(iri.path_segments, @classifier)
      prefix = ""
      keying_host = effective_host(iri.host)
      hinted.map do |entry|
        stats = @storage.position_stats(Position.path(host: keying_host, prefix: prefix))
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

      "{#{entry[:hint] || SegmentClassifier.display_type(entry[:type])}}"
    end

    # Types whose values are often a small fixed set (or a single static
    # value baked into a REST route). For these, run through the same
    # cardinality / value-fraction analysis literals get — a dominant
    # value gets preserved as :stable_literal instead of being
    # placeholdered as a generic {version}/{slug}/etc.
    #
    # Slug + opaque_id are here because a lot of route literals
    # accidentally match those shapes (`/users/{id}/create-new`,
    # reference codes like `WK1234`). When a single value dominates the
    # position, the literal is almost always the better display.
    STABLE_VARIABLE_TYPES = %i[version locale currency boolean slug opaque_id].freeze

    def classify(entry, stats)
      variable = entry[:variable]

      return variable ? :variable_identifier : :ambiguous if stats.nil? || stats.total.zero?
      if variable && !STABLE_VARIABLE_TYPES.include?(entry[:type])
        return :variable_identifier
      end

      value            = entry[:value]
      total            = stats.total
      variable_frac    = stats.variable_fraction(@classifier)
      cardinality_frac = stats.cardinality.to_f / total
      enough_data      = total >= MIN_OBSERVATIONS_FOR_INFERENCE
      value_frac       = stats.value_fraction(value)

      # For STABLE_VARIABLE_TYPES (version, locale, currency, boolean),
      # a dominant value wins over the variable-dominance branch — a
      # single-version /api/v1/... pattern stays as the literal `v1`
      # rather than placeholdering to {version}. Without dominance,
      # fall through to :variable_identifier (the per-type placeholder).
      if variable
        return :stable_literal if value_frac >= STABLE_LITERAL_THRESHOLD

        return :variable_identifier
      end

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

    # Render the query string for normalize output. Prefers the cluster's
    # observed type for each param (dominant type_count); falls back to the
    # mechanical Normalizer.shape_query rules when no cluster signal exists.
    # Date values always emit canonical ISO form regardless of source.
    def render_query(iri)
      hinted_shape = PathShape.new(classifier: @classifier, hints: true)
                              .from_entries(SegmentHints.derive(iri.path_segments, @classifier))
      key, * = Cluster.key_for(iri, classifier: @classifier, shape: hinted_shape,
                               host: effective_host(iri.host))
      cluster = @storage.cluster_for(key)

      iri.query_params.keys.sort.map do |k|
        v = iri.query_params[k].to_s
        type = inferred_param_type(cluster, k, v)
        shaped = render_param_value(v, type)
        "#{k}=#{shaped}"
      end.join("&")
    end

    def inferred_param_type(cluster, name, value)
      # Prefer the cluster's confident type when we have enough samples;
      # otherwise classify the current value directly. Cluster#param_type
      # applies the :date quorum gate (see Cluster::DATE_CONFIDENCE_THRESHOLD).
      stats = cluster && cluster.param_stats[name]
      if stats && stats.total >= MIN_OBSERVATIONS_FOR_INFERENCE
        cluster.param_type(name) || @classifier.classify(value)
      else
        @classifier.classify(value)
      end
    end

    def render_param_value(value, type)
      if type == :date && (canon = SegmentClassifier.canonical_date(value))
        canon
      elsif @classifier.variable?(type)
        "{#{SegmentClassifier.display_type(type)}}"
      else
        value
      end
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
      # Dates render in canonical ISO form rather than as a `{date}` placeholder
      # — matches what mechanical Iriq.normalize does for path segments and
      # what render_param_value does for query params.
      if entry[:type] == :date && (canon = SegmentClassifier.canonical_date(entry[:value]))
        return canon
      end
      return "{#{entry[:hint] || SegmentClassifier.display_type(entry[:type])}}" if entry[:variable]

      # corpus-inferred variable: classifier said literal, corpus says
      # otherwise. Derive a hint from the prefix's last literal segment if
      # we can.
      last_literal = entry[:prefix].split("/").reject(&:empty?).reject { |s| s.start_with?("{") }.last
      base = last_literal ? Inflector.singularize(last_literal) : nil
      base ? "{#{base}}" : "{value}"
    end

    public

    # --- Legacy dump/load (JSON shape) ------------------------------------
    #
    # The pre-Storage release exposed `Corpus#dump`, `Corpus#save(path)`, and
    # `Corpus.load(path)` for JSON-backed persistence. Those names still work
    # but are now thin wrappers around the appropriate Storage backend.

    def dump
      memory_view.to_dump
    end

    def self.from_dump(h, classifier: SegmentClassifier::DEFAULT)
      max_values = h.fetch("max_values_per_position", PositionStats::DEFAULT_MAX_VALUES)
      storage = Storage::Memory.new(classifier: classifier, max_values_per_position: max_values)
      storage.load_dump!(h)
      new(classifier: classifier, storage: storage)
    end

    def self.load(path, classifier: SegmentClassifier::DEFAULT)
      open(path, classifier: classifier)
    end

    private

    def write_json_dump(path)
      tmp = "#{path}.tmp"
      File.write(tmp, JSON.generate(memory_view.to_dump))
      File.rename(tmp, path)
    end

    # Materialize a Memory snapshot of the current state — used by dump for
    # backends that don't natively know how to emit the JSON shape.
    def memory_view
      return @storage if @storage.respond_to?(:to_dump)

      mem = Storage::Memory.new(
        classifier: @classifier,
        max_values_per_position: @storage.max_values_per_position,
      )
      mem.instance_variable_set(:@host_counts,        Hash.new(0).merge(@storage.host_counts))
      mem.instance_variable_set(:@path_length_counts, Hash.new(0).merge(@storage.path_length_counts))
      mem.instance_variable_set(:@raw_shape_counts,   Hash.new(0).merge(@storage.raw_shape_counts))
      mem.instance_variable_set(:@fingerprint_counts, Hash.new(0).merge(@storage.fingerprint_counts))
      ps = {}
      @storage.each_position_stats { |key, stats| ps[key] = stats }
      mem.instance_variable_set(:@position_stats, ps)
      clusters_h = @storage.clusters.each_with_object({}) { |c, h| h[c.key] = c }
      mem.instance_variable_set(:@clusters, clusters_h)
      mem
    end
  end
end
