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
  #   # => "/users/{integer_id}"
  class PathShape
    def initialize(classifier: SegmentClassifier.new, hints: true)
      @classifier = classifier
      @hints      = hints
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

      placeholder = @hints ? (entry[:hint] || entry[:type]) : entry[:type]
      "{#{placeholder}}"
    end

    def self.for(segments, classifier: SegmentClassifier.new, hints: true)
      new(classifier: classifier, hints: hints).for(segments)
    end
  end
end
