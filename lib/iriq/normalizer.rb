module Iriq
  # Produces a canonical, shape-aware string for an identifier.
  #
  #   Normalizer.normalize("https://Foo.com:443/users/123")
  #   # => "https://foo.com/users/{user_id}"
  #
  # The form is intended for grouping/diffing — it is not a round-trippable URL.
  module Normalizer
    module_function

    def normalize(input, classifier: SegmentClassifier::DEFAULT, hints: true)
      iri = input.is_a?(Identifier) ? input : Parser.parse(input)
      normalize_identifier(iri, classifier: classifier, hints: hints)
    end

    def normalize_identifier(iri, classifier: SegmentClassifier::DEFAULT, hints: true)
      if iri.urn?
        if iri.scheme == "urn" && iri.nss && iri.nss.include?(":")
          ns, value = iri.nss.split(":", 2)
          entry     = SegmentHints.derive([ns, value], classifier).last
          shaped    = if entry[:type] == :date && (canon = SegmentClassifier.canonical_date(entry[:value]))
                        canon
                      elsif entry[:type] == :currency && (canon = SegmentClassifier.canonical_currency(entry[:value]))
                        canon
                      elsif entry[:variable]
                        "{#{(hints && entry[:hint]) || SegmentClassifier.display_type(entry[:type])}}"
                      else
                        entry[:value]
                      end
          "urn:#{ns}:#{shaped}"
        else
          iri.canonical
        end
      else
        out = +""
        out << "#{iri.scheme}://" if iri.scheme
        out << iri.host if iri.host
        out << ":#{iri.port}" if iri.port
        out << PathShape.new(classifier: classifier, hints: hints,
                             canonical_dates: true, canonical_currencies: true).for(iri.path_segments)
        if iri.query_params && !iri.query_params.empty?
          out << "?" + shape_query(iri.query_params, classifier)
        end
        out
      end
    end

    def shape_query(params, classifier)
      params.keys.sort.map do |k|
        v      = params[k]
        type   = classifier.classify(v.to_s)
        shaped = if type == :date && (canon = SegmentClassifier.canonical_date(v.to_s))
                   canon
                 elsif type == :currency && (canon = SegmentClassifier.canonical_currency(v.to_s))
                   canon
                 elsif classifier.variable?(type)
                   "{#{SegmentClassifier.display_type(type)}}"
                 else
                   v
                 end
        "#{k}=#{shaped}"
      end.join("&")
    end
  end
end
