module Iriq
  # Groups many identifiers by host + path shape. Use `add` to feed inputs and
  # `clusters` to read out the groups. `explain` annotates a single identifier
  # against the cluster it would fall into, including which positions are
  # stable across all observed members.
  class Clusterer
    def initialize(classifier: SegmentClassifier.new)
      @classifier = classifier
      @clusters   = {}
    end

    def add(input)
      iri = coerce(input)
      key, host, scheme, shape = cluster_key(iri)
      cluster = @clusters[key] ||= Cluster.new(
        key:    key,
        host:   host,
        scheme: scheme,
        shape:  shape,
      )
      cluster.add(iri)
      cluster
    end

    def clusters
      @clusters.values
    end

    def size
      @clusters.size
    end

    # Returns a per-segment explanation for the input, merging classifier
    # output with what we've observed in its cluster (i.e. positions that
    # are factually stable get marked variable: false even if classifier
    # would otherwise call them variable).
    def explain(input)
      iri = coerce(input)
      key, * = cluster_key(iri)
      cluster = @clusters[key]
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

    def cluster_key(iri)
      if iri.urn?
        ns, value = (iri.nss || "").split(":", 2)
        shape = value ? urn_value_shape(ns, value) : nil
        key   = "urn:#{ns}:#{shape}"
        [key, nil, "urn", key]
      else
        shape = PathShape.new(classifier: @classifier).for(iri.path_segments)
        key   = "#{iri.scheme}://#{iri.host}#{shape}"
        [key, iri.host, iri.scheme, shape]
      end
    end

    def urn_value_shape(ns, value)
      entry = SegmentHints.derive([ns, value], @classifier).last
      return entry[:value] unless entry[:variable]

      "{#{entry[:hint] || entry[:type]}}"
    end
  end
end
