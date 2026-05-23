module Iriq
  # Rolling frequency counts for a single (host, prefix-shape, position).
  # Value cardinality is capped so a high-entropy position (UUIDs, timestamps)
  # doesn't grow memory without bound — `total` keeps growing accurately, but
  # only the first `max_values` distinct values are tracked individually.
  class PositionStats
    DEFAULT_MAX_VALUES = 1_000

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
  end
end
