module Iriq
  # A group of identifiers that share a host + shape key. Tracks examples and
  # per-position segment statistics so callers can ask which positions are
  # actually stable in practice (e.g. /users/ always literal, /{integer_id}
  # always variable).
  class Cluster
    attr_reader :key, :host, :scheme, :shape, :examples, :count

    MAX_EXAMPLES = 10

    def initialize(key:, host:, scheme:, shape:)
      @key            = key
      @host           = host
      @scheme         = scheme
      @shape          = shape
      @examples       = []
      @count          = 0
      @segment_counts = []
    end

    def add(identifier)
      @count += 1
      @examples << identifier if @examples.size < MAX_EXAMPLES

      identifier.path_segments.each_with_index do |seg, i|
        @segment_counts[i] ||= Hash.new(0)
        @segment_counts[i][seg] += 1
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
      }
    end
  end
end
