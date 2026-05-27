module Iriq
  # Produces an annotated trace explaining how an identifier got
  # normalized — segment by segment, with notes for each non-obvious
  # transformation (currency upcase, IP umbrella, hint suppression,
  # canonical date, param-name lift, etc.).
  #
  #   Trace.for("https://shop.com/pricing/usd?currency=eur")
  #   # => {
  #   #      input: "...",
  #   #      normalized: "https://shop.com/pricing/USD?currency=EUR",
  #   #      scheme: "https", host: "shop.com",
  #   #      path:  [...per-segment rows...],
  #   #      query: [...per-param rows...],
  #   #    }
  #
  # Each row is `{ value, type, output, notes }` for path entries and
  # `{ name, value, type, output, notes }` for query entries. `output`
  # is the rendered fragment (placeholder or canonical value). `notes`
  # is a list of human-readable strings describing why output differs
  # from value (empty for `literal kept` rows).
  module Trace
    module_function

    HINT_NOTE_TEMPLATE = "semantic type — surfaced as {%s}, not {%s}".freeze

    def for(input, classifier: SegmentClassifier::DEFAULT, hints: true)
      iri = input.is_a?(Identifier) ? input : Parser.parse(input)
      normalized = Normalizer.normalize_identifier(iri, classifier: classifier, hints: hints)

      out = {
        input:      iri.canonical,
        normalized: normalized,
        scheme:     iri.scheme,
        host:       iri.host,
      }
      out[:port] = iri.port if iri.port

      if iri.urn?
        out[:path] = urn_trace(iri, classifier, hints)
      else
        out[:path]  = path_trace(iri.path_segments, classifier, hints)
        out[:query] = query_trace(iri.query_params, classifier) if iri.query_params && !iri.query_params.empty?
      end

      out
    end

    def path_trace(segments, classifier, hints)
      return [] if segments.nil? || segments.empty?

      entries = SegmentHints.derive(segments, classifier)
      entries.each_with_index.map do |e, i|
        segment_row(e, segments, i, classifier, hints)
      end
    end

    def urn_trace(iri, classifier, hints)
      return [] unless iri.nss

      parts = iri.nss.include?(":") ? iri.nss.split(":", 2) : [iri.nss]
      entries = SegmentHints.derive(parts, classifier)
      entries.each_with_index.map do |e, i|
        segment_row(e, parts, i, classifier, hints)
      end
    end

    def query_trace(params, classifier)
      params.keys.sort.map do |k|
        v = params[k].to_s
        base_type = classifier.classify(v)
        notes     = []
        effective = base_type

        if (hint = SegmentClassifier.param_name_hint(k, base_type))
          effective = hint
          notes << "param-name hint (`#{k}=`) lifted #{base_type} → #{hint}"
        end

        output = render_query_value(v, effective, notes)
        { name: k, value: v, type: effective, output: output, notes: notes }
      end
    end

    def segment_row(entry, segments, idx, classifier, hints)
      value = entry[:value]
      type  = entry[:type]
      notes = []

      unless entry[:variable]
        return { value: value, type: type, output: value, notes: notes }
      end

      if type == :date && (canon = SegmentClassifier.canonical_date(value))
        notes << "canonical date (#{value} → #{canon})" if canon != value
        return { value: value, type: type, output: canon, notes: notes }
      end

      if type == :currency && (canon = SegmentClassifier.canonical_currency(value))
        notes << "currency upcase (#{value} → #{canon})" if canon != value
        return { value: value, type: type, output: canon, notes: notes }
      end

      placeholder = placeholder_with_notes(entry, segments, idx, classifier, hints, notes)
      { value: value, type: type, output: "{#{placeholder}}", notes: notes }
    end

    def placeholder_with_notes(entry, segments, idx, classifier, hints, notes)
      type    = entry[:type]
      display = SegmentClassifier.display_type(type)

      if type == :ipv4 || type == :ipv6
        notes << "ip umbrella collapse (#{type} → ip)"
      end

      # If a hint actually applied, surface it as-is.
      return entry[:hint].to_s if hints && entry[:hint]

      # Semantic types skip the noun-singularize hint. Surface the
      # would-be hint so users see WHY {version} is preferred to {api_id}.
      if hints && !SegmentHints::HINT_ELIGIBLE_TYPES.include?(type)
        would_be = would_be_hint(segments, idx, type, classifier)
        if would_be
          notes << format(HINT_NOTE_TEMPLATE, display, would_be)
        end
      end

      display.to_s
    end

    # Returns the hint that would have been generated if this type were
    # hint-eligible. Same neighbor + classification rules as
    # SegmentHints.hint_for, just with the eligibility check stripped.
    def would_be_hint(segments, idx, type, classifier)
      return nil if idx.zero?

      prev = segments[idx - 1]
      return nil unless classifier.classify(prev) == :literal

      base   = Inflector.singularize(prev)
      suffix = type == :uuid ? "_uuid" : "_id"
      "#{base}#{suffix}"
    end

    def render_query_value(value, type, notes)
      if type == :date && (canon = SegmentClassifier.canonical_date(value))
        notes << "canonical date (#{value} → #{canon})" if canon != value
        return canon
      end
      if type == :currency && (canon = SegmentClassifier.canonical_currency(value))
        notes << "currency upcase (#{value} → #{canon})" if canon != value
        return canon
      end
      if SegmentClassifier::DEFAULT.variable?(type)
        if type == :ipv4 || type == :ipv6
          notes << "ip umbrella collapse (#{type} → ip)"
        end
        return "{#{SegmentClassifier.display_type(type)}}"
      end
      value
    end
  end
end
