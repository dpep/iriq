module Iriq
  # Converts a sequence of path segments into a route-shape string by
  # replacing variable segments with `{hint}` placeholders, falling back to
  # `{type}` when no hint is available.
  #
  #   PathShape.for(["users", "123", "orders", "456"])
  #   # => "/users/{user_id}/orders/{order_id}"
  #
  # Pass `hints: false` to use raw types instead:
  #
  #   PathShape.for(["users", "123"], hints: false)
  #   # => "/users/{integer}"
  #
  # Pass `canonical_dates: true` to render date-typed segments in canonical
  # ISO form (2024/01/15 → 2024-01-15) instead of as a `{date}` placeholder.
  # Pass `canonical_currencies: true` for the same treatment of currency
  # codes (`usd` → `USD`). Used by Normalizer for display output; the
  # clusterer keeps the placeholder form so dated/currency routes still
  # group together.
  class PathShape
    def initialize(classifier: SegmentClassifier::DEFAULT, hints: true,
                   canonical_dates: false, canonical_currencies: false)
      @classifier           = classifier
      @hints                = hints
      @canonical_dates      = canonical_dates
      @canonical_currencies = canonical_currencies
    end

    def for(segments)
      return "/" if segments.nil? || segments.empty?

      from_entries(SegmentHints.derive(segments, @classifier))
    end

    # Build a shape string from already-derived SegmentHints entries.
    # Used by Corpus to avoid re-deriving entries per observation when it
    # needs multiple shape variants (raw and hinted).
    def from_entries(entries)
      return "/" if entries.nil? || entries.empty?

      "/" + entries.map { |e| shape_token(e) }.join("/")
    end

    def shape_token(entry)
      return entry[:value] unless entry[:variable]

      if @canonical_dates && entry[:type] == :date &&
         (canon = SegmentClassifier.canonical_date(entry[:value]))
        return canon
      end

      if @canonical_currencies && entry[:type] == :currency &&
         (canon = SegmentClassifier.canonical_currency(entry[:value]))
        return canon
      end

      placeholder = @hints ? (entry[:hint] || SegmentClassifier.display_type(entry[:type])) : SegmentClassifier.display_type(entry[:type])
      "{#{placeholder}}"
    end

    def self.for(segments, classifier: SegmentClassifier::DEFAULT, hints: true,
                 canonical_dates: false, canonical_currencies: false)
      new(classifier: classifier, hints: hints,
          canonical_dates: canonical_dates,
          canonical_currencies: canonical_currencies).for(segments)
    end
  end
end
