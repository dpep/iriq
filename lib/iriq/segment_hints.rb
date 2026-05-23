module Iriq
  # Walks a segment list and annotates each entry with the type, whether it's
  # variable, and a RESTful "hint" (e.g. `user_id`) when a variable segment
  # follows a literal one — `/users/123` ⇒ hint `user_id`.
  module SegmentHints
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

      prev = segments[i - 1]
      return nil unless classifier.classify(prev) == :literal

      base   = Inflector.singularize(prev)
      suffix = type == :uuid ? "_uuid" : "_id"
      "#{base}#{suffix}"
    end
  end
end
