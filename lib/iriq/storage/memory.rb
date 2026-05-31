module Iriq
  module Storage
    # Memory is the canonical backend — every other backend either wraps it
    # (Json) or implements the same surface against an external store (Sqlite).
    #
    # The contract is small enough to enumerate up top:
    #
    #   increment_host(host)
    #   increment_path_length(length)
    #   increment_raw_shape(shape)
    #   increment_fingerprint(shape)
    #   observe_position(position, value, type)        # position is Iriq::Position
    #   add_to_cluster(key, host, scheme, shape, identifier)
    #   record_observation(canonical)                  # append to source-IRI log
    #
    #   host_counts / path_length_counts / raw_shape_counts / fingerprint_counts
    #   position_stats(position)
    #   each_position_stats { |position, stats| ... }
    #   each_observed_iri { |canonical| ... }
    #   clear_materialized_views                       # for reinfer
    #   clusters / cluster_size
    #
    #   transaction { ... }    # backends may batch within
    #   flush                  # commit pending writes (no-op for Memory)
    #   close                  # release resources
    class Memory
      attr_reader :max_values_per_position

      # Path of the underlying file, if any. Memory backends are unpathed;
      # Json/Sqlite override.
      def path; nil; end

      def initialize(classifier: SegmentClassifier::DEFAULT,
                     max_values_per_position: PositionStats::DEFAULT_MAX_VALUES)
        @classifier              = classifier
        @max_values_per_position = max_values_per_position
        @host_counts             = Hash.new(0)
        @path_length_counts      = Hash.new(0)
        @raw_shape_counts        = Hash.new(0)
        @fingerprint_counts      = Hash.new(0)
        @position_stats          = {}
        @clusters                = {}
        # The source-IRI log. Persisted alongside materialized views; the
        # log is the source of truth, the views are derived. Corpus#reinfer
        # drops the views and replays the log through events + reducers.
        @observed_iris           = []
        # Recognizers promoted from RecognizerProposal via
        # Corpus#activate_proposal. Stored as {prefix, type, specificity}
        # hashes so reopens can re-synthesize them onto the corpus's
        # classifier.
        @activated_recognizers   = []
      end

      def transaction
        yield self
      end

      def batch
        yield
      end

      def flush;  end
      def close;  end

      # No-op for in-memory; subclasses override.
      def save(path = nil); end

      # --- Increments -------------------------------------------------------

      def increment_host(host)
        @host_counts[host] += 1 if host
      end

      def increment_path_length(length)
        @path_length_counts[length] += 1
      end

      def increment_raw_shape(shape)
        @raw_shape_counts[shape] += 1
      end

      def increment_fingerprint(shape)
        @fingerprint_counts[shape] += 1
      end

      def observe_position(position, value, type)
        stats = @position_stats[position] ||= PositionStats.new(max_values: @max_values_per_position)
        stats.observe(value, type)
      end

      def add_to_cluster(key, host, scheme, shape, identifier)
        cluster = @clusters[key] ||= Cluster.new(
          key: key, host: host, scheme: scheme, shape: shape,
          max_values: @max_values_per_position,
        )
        cluster.add(identifier, classifier: @classifier)
        cluster
      end

      # Append a canonical IRI to the source-IRI log. Called by Corpus#observe
      # after the event reducers have applied; the log is the source of truth
      # that Corpus#reinfer replays.
      def record_observation(canonical)
        @observed_iris << canonical
      end

      def each_observed_iri(&block)
        @observed_iris.each(&block)
      end

      def observed_iri_count
        @observed_iris.size
      end

      # --- Activated recognizers (Corpus#activate_proposal) -----------------

      def record_activated_recognizer(dump)
        @activated_recognizers << dump
      end

      def each_activated_recognizer(&block)
        @activated_recognizers.each(&block)
      end

      def activated_recognizer_count
        @activated_recognizers.size
      end

      # Drop every materialized view (host_counts, position_stats, clusters,
      # …) without touching the source-IRI log. Corpus#reinfer calls this
      # before replaying the log so views rebuild from scratch.
      def clear_materialized_views
        @host_counts        = Hash.new(0)
        @path_length_counts = Hash.new(0)
        @raw_shape_counts   = Hash.new(0)
        @fingerprint_counts = Hash.new(0)
        @position_stats     = {}
        @clusters           = {}
      end

      # --- Reads ------------------------------------------------------------

      def host_counts;        @host_counts;        end
      def path_length_counts; @path_length_counts; end
      def raw_shape_counts;   @raw_shape_counts;   end
      def fingerprint_counts; @fingerprint_counts; end

      def position_stats(position)
        @position_stats[position]
      end

      def each_position_stats(&block)
        @position_stats.each(&block)
      end

      def clusters
        @clusters.values
      end

      def cluster_size
        @clusters.size
      end

      # O(1) lookup by cluster key — used by Corpus#normalize to pull the
      # cluster's param_stats for the URL being normalized. nil if no cluster
      # has been observed under this key yet.
      def cluster_for(key)
        @clusters[key]
      end

      # --- Bulk load (used by JSON backend) --------------------------------

      def load_dump!(h)
        @host_counts        = Hash.new(0).merge(h["host_counts"])
        @path_length_counts = Hash.new(0).merge(h["path_length_counts"].transform_keys(&:to_i))
        @raw_shape_counts   = Hash.new(0).merge(h["raw_shape_counts"])
        @fingerprint_counts = Hash.new(0).merge(h["fingerprint_counts"])
        @max_values_per_position = h.fetch("max_values_per_position", PositionStats::DEFAULT_MAX_VALUES)
        @position_stats = h["position_stats"].each_with_object({}) do |entry, acc|
          position = Position.from_dump(entry["position"])
          acc[position] = PositionStats.from_dump(entry["stats"])
        end
        cdump = h.fetch("clusterer", { "clusters" => {} })
        @clusters = cdump["clusters"].transform_values { |c| Cluster.from_dump(c, max_values: @max_values_per_position) }
        @observed_iris         = h.fetch("observed_iris", [])
        @activated_recognizers = h.fetch("activated_recognizers", [])
        self
      end

      def to_dump
        {
          "host_counts"             => @host_counts,
          "path_length_counts"      => @path_length_counts.transform_keys(&:to_s),
          "raw_shape_counts"        => @raw_shape_counts,
          "fingerprint_counts"      => @fingerprint_counts,
          "max_values_per_position" => @max_values_per_position,
          "position_stats"          => @position_stats.map { |pos, s|
            { "position" => pos.to_dump, "stats" => s.dump }
          },
          "clusterer"               => {
            "clusters" => @clusters.transform_values(&:dump),
          },
          "observed_iris"           => @observed_iris,
          "activated_recognizers"   => @activated_recognizers,
        }
      end
    end
  end
end
