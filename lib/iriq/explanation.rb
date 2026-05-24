module Iriq
  # Builds a per-segment explanation for a single identifier.
  #
  #   Explanation.explain("https://foo.com/users/123")
  #   # => [
  #   #      { value: "users", type: :literal,    variable: false, hint: nil       },
  #   #      { value: "123",   type: :integer_id, variable: true,  hint: "user_id" },
  #   #    ]
  module Explanation
    module_function

    def explain(input, classifier: SegmentClassifier::DEFAULT)
      iri = input.is_a?(Identifier) ? input : Parser.parse(input)

      if iri.urn?
        explain_urn(iri, classifier)
      else
        SegmentHints.derive(iri.path_segments, classifier)
      end
    end

    def explain_urn(iri, classifier)
      return [] unless iri.nss

      parts = iri.nss.include?(":") ? iri.nss.split(":", 2) : [iri.nss]
      SegmentHints.derive(parts, classifier)
    end
  end
end
