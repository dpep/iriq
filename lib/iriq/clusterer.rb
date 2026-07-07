module Iriq
  # Groups many identifiers by host + path shape. Use `add` to feed inputs and
  # `clusters` to read out the groups. `explain` annotates a single identifier
  # against the cluster it would fall into, including which positions are
  # stable across all observed members.
  #
  # Implemented as a thin wrapper over Storage::Memory — the same code path
  # Corpus uses for the cluster portion of its state, so there's only one
  # place that knows how clusters get stored.
  class Clusterer
    def initialize(classifier: SegmentClassifier::DEFAULT)
      @classifier = classifier
      @storage    = Storage::Memory.new(classifier: classifier)
    end

    def add(input, shape: nil)
      iri = coerce(input)
      key, host, scheme, derived = Cluster.key_for(iri, classifier: @classifier, shape: shape)
      @storage.add_to_cluster(key, host, scheme, derived, iri)
    end

    def clusters
      @storage.clusters
    end

    def size
      @storage.cluster_size
    end

    # Returns a per-segment explanation for the input, merging classifier
    # output with what we've observed in its cluster (i.e. positions that
    # are factually stable get marked variable: false even if classifier
    # would otherwise call them variable).
    def explain(input)
      iri = coerce(input)
      key, * = Cluster.key_for(iri, classifier: @classifier)
      cluster = clusters.find { |c| c.key == key }
      stats   = cluster ? cluster.segment_stats : []
      hinted  = SegmentHints.derive(iri.path_segments, @classifier)

      hinted.each_with_index.map do |entry, i|
        stable = stats[i] && stats[i][:stable]
        entry.merge(
          variable: !stable && entry[:variable],
          stable:   !!stable,
        )
      end
    end

    private

    def coerce(input)
      input.is_a?(Identifier) ? input : Parser.parse(input)
    end
  end
end
