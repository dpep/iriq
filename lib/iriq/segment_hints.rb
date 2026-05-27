require "set"

module Iriq
  # Walks a segment list and annotates each entry with the type, whether it's
  # variable, and a RESTful "hint" (e.g. `user_id`) when a variable segment
  # follows a literal one — `/users/123` ⇒ hint `user_id`.
  module SegmentHints
    # Only ID-shaped types get the noun-singularize hint. Semantic types
    # (version, locale, currency, date, etc.) are more informative as
    # `{type}` than as `{noun}_id` — `/api/v1/...` should render
    # `{version}`, not `{api_id}`.
    HINT_ELIGIBLE_TYPES = %i[integer uuid hash opaque_id slug].to_set.freeze

    module_function

    def derive(segments, classifier)
      segments.each_with_index.map do |seg, i|
        type     = classifier.classify(seg)
        variable = classifier.variable?(type)
        {
          value:    seg,
          type:     type,
          variable: variable,
          hint:     hint_for(segments, i, type, variable, classifier),
        }
      end
    end

    def hint_for(segments, i, type, variable, classifier)
      return nil unless variable && i > 0
      return nil unless HINT_ELIGIBLE_TYPES.include?(type)

      prev = segments[i - 1]
      return nil unless classifier.classify(prev) == :literal

      base   = Inflector.singularize(prev)
      suffix = type == :uuid ? "_uuid" : "_id"
      "#{base}#{suffix}"
    end
  end
end
