module Iriq
  # Produces a canonical, shape-aware string for an identifier.
  #
  #   Normalizer.normalize("https://Foo.com:443/users/123")
  #   # => "https://foo.com/users/{user_id}"
  #
  # The form is intended for grouping/diffing — it is not a round-trippable URL.
  #
  # Path + query rendering dispatches through an evidence source so the
  # mechanical (classifier-only) and corpus-informed code paths share one
  # entry point. When `evidence` is nil, NullEvidenceSource provides the
  # mechanical behavior (PathShape + param-name-hint query rules). When a
  # Corpus is passed as `evidence`, its observed Position / Cluster stats
  # drive the rendering (variability promotion, popular outlier
  # preservation, cluster-inferred query types).
  module Normalizer
    module_function

    def normalize(input, classifier: SegmentClassifier::DEFAULT, hints: true, evidence: nil)
      iri = input.is_a?(Identifier) ? input : Parser.parse(input)
      normalize_identifier(iri, classifier: classifier, hints: hints, evidence: evidence)
    end

    def normalize_identifier(iri, classifier: SegmentClassifier::DEFAULT, hints: true, evidence: nil)
      return normalize_urn(iri, classifier, hints) if iri.urn?

      src = evidence || NullEvidenceSource.new
      out = +""
      out << "#{iri.scheme}://" if iri.scheme
      out << iri.host if iri.host
      out << ":#{iri.port}" if iri.port
      out << src.render_path(iri, classifier, hints)
      if iri.query_params && !iri.query_params.empty?
        out << "?" << src.render_query(iri, classifier)
      end
      out
    end

    def normalize_urn(iri, classifier, hints)
      return iri.canonical unless iri.scheme == "urn" && iri.nss && iri.nss.include?(":")

      ns, value = iri.nss.split(":", 2)
      entry     = SegmentHints.derive([ns, value], classifier).last
      shaped =
        if entry[:type] == :date && (canon = SegmentClassifier.canonical_date(entry[:value]))
          canon
        elsif entry[:type] == :currency && (canon = SegmentClassifier.canonical_currency(entry[:value]))
          canon
        elsif entry[:variable]
          "{#{(hints && entry[:hint]) || SegmentClassifier.display_type(entry[:type])}}"
        else
          entry[:value]
        end
      "urn:#{ns}:#{shaped}"
    end
  end

  # NullEvidenceSource is the default evidence source — purely
  # classifier-driven, no corpus signal. The Normalizer's mechanical
  # behavior is what this produces. Implements the same {render_path,
  # render_query} interface that Corpus implements for the corpus-informed
  # path.
  class NullEvidenceSource
    def render_path(iri, classifier, hints)
      PathShape.new(
        classifier: classifier, hints: hints,
        canonical_dates: true, canonical_currencies: true,
      ).for(iri.path_segments)
    end

    def render_query(iri, classifier)
      iri.query_params.keys.sort.map do |k|
        v    = iri.query_params[k]
        type = classifier.classify(v.to_s)
        # Param-name hint can lift a generic literal/opaque_id/slug into
        # a semantic type — `?phone=unknown` becomes `{phone}`.
        if (hint = SegmentClassifier.param_name_hint(k, type))
          type = hint
        end
        shaped =
          if type == :date && (canon = SegmentClassifier.canonical_date(v.to_s))
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
