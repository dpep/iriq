module Iriq
  # Converts a sequence of path segments into a route-shape string by
  # replacing variable segments with `{type}` placeholders.
  #
  #   PathShape.for(["users", "123", "orders", "456"])
  #   # => "/users/{integer_id}/orders/{integer_id}"
  class PathShape
    def initialize(classifier: SegmentClassifier.new)
      @classifier = classifier
    end

    def for(segments)
      return "/" if segments.nil? || segments.empty?

      "/" + segments.map { |s| shape_segment(s) }.join("/")
    end

    def shape_segment(segment)
      type = @classifier.classify(segment)
      @classifier.variable?(type) ? "{#{type}}" : segment
    end

    def self.for(segments, classifier: SegmentClassifier.new)
      new(classifier: classifier).for(segments)
    end
  end
end
