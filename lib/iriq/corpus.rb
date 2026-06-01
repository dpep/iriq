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

    attr_reader :storage, :host_strategy, :classifier

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
      corpus = new(classifier: classifier, storage: storage, host_strategy: host_strategy)
      corpus.send(:reapply_activated_recognizers!) if storage.respond_to?(:each_activated_recognizer)
      corpus
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
    #
    # Internally: builds an Event list for the IRI, then applies each event
    # through the Reducer registry inside a single storage transaction. The
    # event list is transient today — a future commit can persist it and
    # replay against alternate reducers / thresholds for re-runnable
    # inference. See lib/iriq/event.rb and lib/iriq/reducer.rb.
    def observe(input)
      iri     = coerce(input)
      events  = events_for(iri)
      cluster = nil

      @storage.transaction do |s|
        events.each do |e|
          result = Reducer.apply(e, s)
          cluster = result if e.is_a?(Event::ClusterAddition)
        end
        s.record_observation(iri.canonical) if s.respond_to?(:record_observation)
      end

      Observation.new(corpus: self, identifier: iri, cluster: cluster)
    end

    # Drop every materialized view (host counts, position stats, clusters,
    # …) and rebuild them by replaying the source-IRI log through the
    # current events + reducers pipeline. Useful for:
    #
    #   - Tuning thresholds (swap a Corpus constant, call reinfer)
    #   - Swapping the classifier (open the Corpus with a different
    #     classifier, call reinfer — events are re-derived from raw IRIs)
    #   - Recovering after a Reducer-set change
    #
    # Wrapped in a single backend transaction so a failure mid-replay
    # leaves the prior views intact.
    def reinfer
      @storage.transaction do |s|
        iris = []
        s.each_observed_iri { |canonical| iris << canonical }
        s.clear_materialized_views
        iris.each do |canonical|
          iri = Parser.parse(canonical)
          events_for(iri).each { |e| Reducer.apply(e, s) }
        end
      end
      nil
    end

    # Number of IRIs in the source-IRI log. The materialized views are
    # derived from this log; reinfer replays it.
    def observed_iri_count
      return @storage.observed_iri_count if @storage.respond_to?(:observed_iri_count)
      0
    end

    # Scan observed values for shape patterns that recur frequently enough
    # to suggest a new Recognizer. Returns RecognizerProposal records; nothing
    # is automatically applied — the proposal carries enough evidence for a
    # human to decide whether to bake the Recognizer in.
    #
    # Strategies are pluggable; the default set lives in
    # Iriq::ProposalStrategy::DEFAULTS. Pass `strategies:` to limit / extend.
    # Pass `min_observations:` / `min_coverage:` / `min_hosts:` to tune
    # what passes the noise floor.
    def propose_recognizers(strategies: ProposalStrategy::DEFAULTS, **opts)
      strategies.flat_map { |s| s.propose(@storage, **opts) }
    end

    # Promote a RecognizerProposal into a live Recognizer for this corpus.
    #
    # Mechanics:
    #   1. Synthesize a SynthesizedRecognizer from the proposal's prefix.
    #   2. Switch to a per-corpus classifier (if we were sharing the
    #      module-level DEFAULT) so activation doesn't leak to other
    #      corpora using the same default singleton.
    #   3. Register the Recognizer on the classifier — the ensemble
    #      picks it up on the next classify() call.
    #   4. Persist the activation in storage so reopens re-apply it.
    #   5. Reinfer so existing observations get re-classified through
    #      the new Recognizer.
    #
    # Returns the synthesized Recognizer.
    def activate_proposal(proposal)
      recognizer = SynthesizedRecognizer.from_proposal(proposal)
      ensure_per_corpus_classifier!
      @classifier.register_recognizer(recognizer)
      if @storage.respond_to?(:record_activated_recognizer)
        @storage.record_activated_recognizer(recognizer.to_dump)
      end
      reinfer
      recognizer
    end

    # Convenience: activate every proposal whose confidence clears the
    # given threshold. Returns the activated Recognizers. Confidence
    # incorporates both per-position coverage AND cross-host
    # corroboration — see RecognizerProposal#compute_confidence.
    def activate_proposals_above(confidence_threshold, **propose_opts)
      proposals = propose_recognizers(**propose_opts)
      proposals.select { |p| p.confidence >= confidence_threshold }.map { |p| activate_proposal(p) }
    end

    # Number of activated recognizers persisted with this corpus.
    def activated_recognizer_count
      return @storage.activated_recognizer_count if @storage.respond_to?(:activated_recognizer_count)
      0
    end

    # Route shapes that recur across `min_hosts` or more distinct hosts.
    # Returns CrossHostShape records sorted by host_count desc, then by
    # observation_count desc, then by shape (stable, deterministic).
    #
    # Cross-host recurrence is independent evidence of a real semantic
    # pattern — two unrelated hosts inventing the same `/users/{integer}`
    # structure by accident is unlikely. A natural follow-up is feeding
    # this signal back into RecognizerProposal confidence: a proposal
    # supported by N hosts is much stronger than one seen on a single
    # host with the same per-position coverage.
    def cross_host_shapes(min_hosts: 2)
      by_shape = Hash.new { |h, k| h[k] = { hosts: Set.new, count: 0 } }
      @storage.clusters.each do |cluster|
        # Skip non-URL clusters (URN clusters have no host).
        next if cluster.host.nil? || cluster.host.empty?

        agg = by_shape[cluster.shape]
        agg[:hosts] << cluster.host
        agg[:count] += cluster.count
      end

      by_shape.filter_map do |shape, data|
        next nil if data[:hosts].size < min_hosts

        CrossHostShape.new(
          shape:             shape,
          hosts:             data[:hosts],
          observation_count: data[:count],
        )
      end.sort_by { |s| [-s.host_count, -s.observation_count, s.shape] }
    end

    # Build the ordered Event list for `input` without applying it. Useful
    # for inspection, tests, and future event-log persistence. Each call is
    # pure — no storage side-effects.
    def events_for(input)
      iri = coerce(input)
      hinted_entries = SegmentHints.derive(iri.path_segments, @classifier)
      raw_shape    = PathShape.new(classifier: @classifier, hints: false).from_entries(hinted_entries)
      hinted_shape = PathShape.new(classifier: @classifier, hints: true).from_entries(hinted_entries)
      keying_host  = effective_host(iri.host)

      events = [
        Event::HostSeen.new(keying_host),
        Event::PathLengthSeen.new(iri.path_segments.size),
        Event::RawShapeSeen.new(raw_shape),
        Event::FingerprintSeen.new(hinted_shape),
      ]

      prefix = ""
      hinted_entries.each do |entry|
        events << Event::PositionSeen.new(
          Position.path(host: keying_host, prefix: prefix),
          entry[:value], entry[:type],
        )
        prefix = "#{prefix}/#{placeholder(entry)}"
      end

      key, host, scheme, shape = Cluster.key_for(iri, classifier: @classifier, shape: hinted_shape, host: keying_host)
      events << Event::ClusterAddition.new(key, host, scheme, shape, iri)

      events
    end

    # Corpus-informed normalization. Falls back to mechanical normalization
    # when the corpus has no signal for a position. Implemented as a thin
    # call into Normalizer with `evidence: self`; the corpus-informed path
    # and query rendering live in #render_path / #render_query below
    # (the evidence-source interface).
    def normalize(input)
      iri = coerce(input)
      Normalizer.normalize_identifier(iri, classifier: @classifier, hints: true, evidence: self)
    end

    # Evidence-source interface — called by Normalizer when this Corpus is
    # passed as `evidence:`. Renders the path using corpus-informed
    # classifications (variability promotion, popular-outlier preservation).
    # Always emits a leading "/" — empty path collapses to "/" to match
    # mechanical output and anchor any trailing query.
    def render_path(iri, _classifier, _hints)
      tokens = annotate_segments(iri).map { |entry| corpus_token(entry) }
      "/" + tokens.join("/")
    end

    # Evidence-source interface — render the query string with
    # cluster-inferred param types where available. The mechanical
    # NullEvidenceSource provides the classifier-only fallback; this
    # version prefers the cluster's observed type per param (dominant
    # type_count, subject to the corpus thresholds).
    def render_query(iri, _classifier = @classifier)
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

    # If we're still sharing the module-level DEFAULT classifier, switch
    # to our own copy so register_recognizer doesn't leak into other
    # corpora using the same default singleton.
    def ensure_per_corpus_classifier!
      return if @classifier != SegmentClassifier::DEFAULT

      @classifier = SegmentClassifier.new
    end

    # On Corpus.open, walk the stored activations and register each one
    # on this corpus's classifier. Switches to a per-corpus classifier
    # if any activations exist.
    def reapply_activated_recognizers!
      return if @storage.activated_recognizer_count.zero?

      ensure_per_corpus_classifier!
      @storage.each_activated_recognizer do |dump|
        @classifier.register_recognizer(SynthesizedRecognizer.from_dump(dump))
      end
    end

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
