module Iriq
  # Rolling frequency counts for a single (host, prefix-shape, position).
  # Value cardinality is capped so a high-entropy position (UUIDs, timestamps)
  # doesn't grow memory without bound — `total` keeps growing accurately, but
  # only the first `max_values` distinct values are tracked individually.
  # Existing tracked values still receive increments after the cap is hit;
  # only NEW distinct values are dropped.
  class PositionStats
    DEFAULT_MAX_VALUES = 5_000

    attr_reader :value_counts, :type_counts, :total, :max_values

    def initialize(max_values: DEFAULT_MAX_VALUES)
      @value_counts = Hash.new(0)
      @type_counts  = Hash.new(0)
      @total        = 0
      @max_values   = max_values
    end

    def observe(value, type)
      @total += 1
      @type_counts[type] += 1
      if @value_counts.size < @max_values || @value_counts.key?(value)
        @value_counts[value] += 1
      end
    end

    def cardinality
      @value_counts.size
    end

    # Fraction of observations whose type was variable (i.e. classifier said
    # not :literal).
    def variable_fraction(classifier)
      return 0.0 if @total.zero?

      var = @type_counts.sum { |t, c| classifier.variable?(t) ? c : 0 }
      var.to_f / @total
    end

    def value_fraction(value)
      return 0.0 if @total.zero?

      (@value_counts[value] || 0).to_f / @total
    end

    # Most common type. On count ties, breaks lexicographically by type
    # symbol name so the result is deterministic and matches Go's
    # DominantType (Go's map iteration is randomized).
    def dominant_type
      best = nil
      best_count = -1
      @type_counts.each do |t, n|
        if n > best_count || (n == best_count && t.to_s < best.to_s)
          best = t
          best_count = n
        end
      end
      best
    end

    def dump
      # Dup the hashes so callers can mutate the dump structure (test
      # fixtures, post-processing) without aliasing the live state.
      {
        "value_counts" => @value_counts.dup,
        "type_counts"  => @type_counts.transform_keys(&:to_s),
        "total"        => @total,
        "max_values"   => @max_values,
      }
    end

    def self.from_dump(h)
      stats = new(max_values: h["max_values"])
      stats.instance_variable_set(:@total, h["total"])
      vc = Hash.new(0).merge(h["value_counts"])
      tc = Hash.new(0).merge(h["type_counts"].transform_keys(&:to_sym))
      stats.instance_variable_set(:@value_counts, vc)
      stats.instance_variable_set(:@type_counts, tc)
      stats
    end
  end
end
