module Iriq
  # Builds a per-segment explanation for a single identifier.
  #
  #   Explanation.explain("https://foo.com/users/123")
  #   # => [
  #   #      { value: "users", type: :literal,    variable: false },
  #   #      { value: "123",   type: :integer_id, variable: true },
  #   #    ]
  module Explanation
    module_function

    def explain(input, classifier: SegmentClassifier.new)
      iri = input.is_a?(Identifier) ? input : Parser.parse(input)

      if iri.urn?
        explain_urn(iri, classifier)
      else
        iri.path_segments.map { |s| segment_entry(s, classifier) }
      end
    end

    def segment_entry(segment, classifier)
      type = classifier.classify(segment)
      {
        value:    segment,
        type:     type,
        variable: classifier.variable?(type),
      }
    end

    def explain_urn(iri, classifier)
      return [] unless iri.nss

      if iri.nss.include?(":")
        ns, value = iri.nss.split(":", 2)
        [
          { value: ns, type: :literal, variable: false },
          segment_entry(value, classifier),
        ]
      else
        [segment_entry(iri.nss, classifier)]
      end
    end
  end
end
