module Iriq
  # Renderer that produces a route-shape string by replacing variable
  # segments with `{hint}` placeholders. As of v0.16 this is a thin wrapper
  # around Iriq::Shape — kept for back-compat with callers that still want
  # to get a string in one call.
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
  # codes (`usd` → `USD`).
  #
  # For new code, prefer building an Iriq::Shape directly and calling
  # `#render`. PathShape stays available for the common string-only path.
  class PathShape
    def initialize(classifier: SegmentClassifier::DEFAULT, hints: true,
                   canonical_dates: false, canonical_currencies: false)
      @classifier           = classifier
      @hints                = hints
      @canonical_dates      = canonical_dates
      @canonical_currencies = canonical_currencies
    end

    def for(segments)
      from_entries(SegmentHints.derive(segments || [], @classifier))
    end

    # Build a shape string from already-derived SegmentHints entries.
    def from_entries(entries)
      Shape.from_entries(entries).render(
        hints: @hints,
        canonical_dates: @canonical_dates,
        canonical_currencies: @canonical_currencies,
      )
    end

    def self.for(segments, classifier: SegmentClassifier::DEFAULT, hints: true,
                 canonical_dates: false, canonical_currencies: false)
      new(classifier: classifier, hints: hints,
          canonical_dates: canonical_dates,
          canonical_currencies: canonical_currencies).for(segments)
    end
  end
end
