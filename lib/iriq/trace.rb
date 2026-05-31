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
  # `{ name, value, type, output, notes }` for query entries. The string
  # notes are rendered from structured Iriq::Evidence::Record values;
  # callers that want the structured form can use Trace.evidence_for.
  module Trace
    module_function

    HINT_NOTE_TEMPLATE = "semantic type — surfaced as {%s}, not {%s}".freeze

    # Render-ready Trace output. The public format consumers depend on.
    def for(input, classifier: SegmentClassifier::DEFAULT, hints: true)
      iri = coerce(input)
      normalized = Normalizer.normalize_identifier(iri, classifier: classifier, hints: hints)

      out = {
        input:      iri.canonical,
        normalized: normalized,
        scheme:     iri.scheme,
        host:       iri.host,
      }
      out[:port] = iri.port if iri.port

      if iri.urn?
        out[:path] = urn_rows(iri, classifier, hints)
      else
        out[:path]  = path_rows(iri.path_segments, classifier, hints)
        if iri.query_params && !iri.query_params.empty?
          out[:query] = query_rows(iri.query_params, classifier)
        end
      end

      out
    end

    # Structured Evidence list for `input`. Each segment + query param
    # contributes one classification Evidence plus zero or more
    # transformation Evidence records (canonical date, IP umbrella
    # collapse, param-name hint, hint suppression).
    #
    # Position + Cluster Evidence are not emitted here — they belong to
    # corpus-informed trace (Corpus#trace), which a follow-up step lands.
    def evidence_for(input, classifier: SegmentClassifier::DEFAULT, hints: true)
      iri      = coerce(input)
      records  = []
      segments = iri.urn? ? urn_parts(iri) : (iri.path_segments || [])
      entries  = SegmentHints.derive(segments, classifier)

      entries.each_with_index do |entry, i|
        records.concat(segment_evidence(entry, segments, i, classifier, hints))
      end

      if !iri.urn? && iri.query_params && !iri.query_params.empty?
        iri.query_params.keys.sort.each do |k|
          records.concat(query_param_evidence(k, iri.query_params[k].to_s, classifier))
        end
      end

      records
    end

    # ── Evidence builders ────────────────────────────────────────────────

    def segment_evidence(entry, segments, idx, classifier, hints)
      records = []

      records << Evidence.segment(
        index: idx, value: entry[:value],
        source:  :recognizer,
        payload: { type: entry[:type], variable: entry[:variable], hint: entry[:hint] },
      )

      if entry[:variable]
        if entry[:type] == :date && (canon = SegmentClassifier.canonical_date(entry[:value]))
          if canon != entry[:value]
            records << Evidence.segment(
              index: idx, value: entry[:value],
              source:  :policy,
              payload: { rule: :canonical_date, before: entry[:value], after: canon },
              notes:   ["canonical date (#{entry[:value]} → #{canon})"],
            )
          end
        elsif entry[:type] == :currency && (canon = SegmentClassifier.canonical_currency(entry[:value]))
          if canon != entry[:value]
            records << Evidence.segment(
              index: idx, value: entry[:value],
              source:  :policy,
              payload: { rule: :canonical_currency, before: entry[:value], after: canon },
              notes:   ["currency upcase (#{entry[:value]} → #{canon})"],
            )
          end
        else
          extra = placeholder_decoration_evidence(entry, segments, idx, classifier, hints)
          records.concat(extra)
        end
      end

      records
    end

    def placeholder_decoration_evidence(entry, segments, idx, classifier, hints)
      out  = []
      type = entry[:type]

      if type == :ipv4 || type == :ipv6
        out << Evidence.segment(
          index: idx, value: entry[:value],
          source:  :policy,
          payload: { rule: :ip_umbrella_collapse, from: type, to: :ip },
          notes:   ["ip umbrella collapse (#{type} → ip)"],
        )
      end

      if hints && entry[:hint].nil? && !SegmentHints::HINT_ELIGIBLE_TYPES.include?(type)
        if (would_be = would_be_hint(segments, idx, type, classifier))
          display = SegmentClassifier.display_type(type)
          out << Evidence.segment(
            index: idx, value: entry[:value],
            source:  :neighbor,
            payload: { rule: :hint_suppression, surfaced: display, would_be: would_be, semantic_type: type },
            notes:   [format(HINT_NOTE_TEMPLATE, display, would_be)],
          )
        end
      end

      out
    end

    def query_param_evidence(name, value, classifier)
      records   = []
      base_type = classifier.classify(value)
      effective = base_type

      if (hint = SegmentClassifier.param_name_hint(name, base_type))
        effective = hint
        records << Evidence.segment(
          index: name, value: value,
          source:  :neighbor,
          payload: { rule: :param_name_hint, name: name, before: base_type, after: hint },
          notes:   ["param-name hint (`#{name}=`) lifted #{base_type} → #{hint}"],
        )
      end

      records << Evidence.segment(
        index: name, value: value,
        source:  :recognizer,
        payload: { type: effective, variable: SegmentClassifier::DEFAULT.variable?(effective) },
      )

      if effective == :date && (canon = SegmentClassifier.canonical_date(value))
        if canon != value
          records << Evidence.segment(
            index: name, value: value,
            source:  :policy,
            payload: { rule: :canonical_date, before: value, after: canon },
            notes:   ["canonical date (#{value} → #{canon})"],
          )
        end
      elsif effective == :currency && (canon = SegmentClassifier.canonical_currency(value))
        if canon != value
          records << Evidence.segment(
            index: name, value: value,
            source:  :policy,
            payload: { rule: :canonical_currency, before: value, after: canon },
            notes:   ["currency upcase (#{value} → #{canon})"],
          )
        end
      elsif effective == :ipv4 || effective == :ipv6
        records << Evidence.segment(
          index: name, value: value,
          source:  :policy,
          payload: { rule: :ip_umbrella_collapse, from: effective, to: :ip },
          notes:   ["ip umbrella collapse (#{effective} → ip)"],
        )
      end

      records
    end

    # ── View rendering (Evidence → Trace.for hash) ───────────────────────

    def path_rows(segments, classifier, hints)
      return [] if segments.nil? || segments.empty?

      entries = SegmentHints.derive(segments, classifier)
      entries.each_with_index.map do |entry, i|
        ev = segment_evidence(entry, segments, i, classifier, hints)
        render_segment_row(entry, ev, hints)
      end
    end

    def urn_rows(iri, classifier, hints)
      parts = urn_parts(iri)
      return [] if parts.empty?

      entries = SegmentHints.derive(parts, classifier)
      entries.each_with_index.map do |entry, i|
        ev = segment_evidence(entry, parts, i, classifier, hints)
        render_segment_row(entry, ev, hints)
      end
    end

    def query_rows(params, classifier)
      params.keys.sort.map do |k|
        v  = params[k].to_s
        ev = query_param_evidence(k, v, classifier)
        render_query_row(k, v, ev)
      end
    end

    def render_segment_row(entry, evidence, hints)
      notes = collect_notes(evidence)
      value = entry[:value]
      type  = entry[:type]

      return { value: value, type: type, output: value, notes: notes } unless entry[:variable]

      canon_policy = find_payload(evidence, :canonical_date) || find_payload(evidence, :canonical_currency)
      if canon_policy
        return { value: value, type: type, output: canon_policy[:after], notes: notes }
      end

      placeholder = hints && entry[:hint] ? entry[:hint].to_s : SegmentClassifier.display_type(type).to_s
      { value: value, type: type, output: "{#{placeholder}}", notes: notes }
    end

    def render_query_row(name, value, evidence)
      notes        = collect_notes(evidence)
      cls          = find_evidence(evidence, source: :recognizer)
      effective    = cls ? cls.payload[:type] : SegmentClassifier::DEFAULT.classify(value)
      canon_policy = find_payload(evidence, :canonical_date) || find_payload(evidence, :canonical_currency)

      output =
        if canon_policy
          canon_policy[:after]
        elsif SegmentClassifier::DEFAULT.variable?(effective)
          "{#{SegmentClassifier.display_type(effective)}}"
        else
          value
        end

      { name: name, value: value, type: effective, output: output, notes: notes }
    end

    # ── Helpers ──────────────────────────────────────────────────────────

    def coerce(input)
      input.is_a?(Identifier) ? input : Parser.parse(input)
    end

    def urn_parts(iri)
      return [] unless iri.nss
      iri.nss.include?(":") ? iri.nss.split(":", 2) : [iri.nss]
    end

    def collect_notes(evidence)
      evidence.flat_map(&:notes)
    end

    def find_evidence(evidence, source:)
      evidence.find { |r| r.source == source }
    end

    def find_payload(evidence, rule)
      r = evidence.find { |e| e.source == :policy && e.payload[:rule] == rule }
      r&.payload
    end

    def would_be_hint(segments, idx, type, classifier)
      return nil if idx.zero?

      prev = segments[idx - 1]
      return nil unless classifier.classify(prev) == :literal

      base   = Inflector.singularize(prev)
      suffix = type == :uuid ? "_uuid" : "_id"
      "#{base}#{suffix}"
    end
  end
end
