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

      iri.path_segments.each_with_index.map do |seg, i|
        type   = @classifier.classify(seg)
        stable = stats[i] && stats[i][:stable]
        {
          value:    seg,
          type:     type,
          variable: !stable && @classifier.variable?(type),
          stable:   !!stable,
        }
      end
    end

    private

    def coerce(input)
      input.is_a?(Identifier) ? input : Parser.parse(input)
    end

    def cluster_key(iri)
      if iri.urn?
        ns, value = (iri.nss || "").split(":", 2)
        shape = if value
          type = @classifier.classify(value)
          @classifier.variable?(type) ? "{#{type}}" : value
        end
        key = "urn:#{ns}:#{shape}"
        [key, nil, "urn", key]
      else
        shape = PathShape.new(classifier: @classifier).for(iri.path_segments)
        key   = "#{iri.scheme}://#{iri.host}#{shape}"
        [key, iri.host, iri.scheme, shape]
      end
    end
  end
end
