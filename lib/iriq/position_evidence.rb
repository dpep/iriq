module Iriq
  # The slice of a position's stats that classifying one value reads
  # (Corpus#classify). A backend can answer it without materializing every
  # value tracked at the position.
  PositionEvidence = Struct.new(:total, :type_counts, :cardinality, :value_count, keyword_init: true) do
    # value_count is nil when the value isn't tracked (never seen, or dropped
    # at the cap).
    def self.from_stats(stats, value)
      new(
        total:       stats.total,
        type_counts: stats.type_counts,
        cardinality: stats.cardinality,
        value_count: stats.value_counts.fetch(value, nil),
      )
    end

    # Same as PositionStats#variable_fraction.
    def variable_fraction(classifier)
      return 0.0 if total.zero?

      type_counts.sum { |t, c| classifier.variable?(t) ? c : 0 }.to_f / total
    end

    # Same as PositionStats#value_fraction for the probed value.
    def value_fraction
      return 0.0 if total.zero?

      (value_count || 0).to_f / total
    end
  end
end
