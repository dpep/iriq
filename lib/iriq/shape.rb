module Iriq
  # Structured route shape: an ordered list of typed segment entries plus
  # rendering methods that produce the various string forms (placeholder,
  # canonical-dates, raw-types, etc.).
  #
  # Replaces the string-as-data convention where PathShape's String output
  # was the only carrier of shape information. Structured Shape makes:
  #   - downstream consumers cheap (they iterate entries instead of
  #     re-deriving from segments + classifier)
  #   - shape identity explicit (structural #== / #hash, not string match)
  #   - multiple renderings free (canonical dates, hints on/off, raw types
  #     vs hinted) without re-walking segments
  #
  # The cluster identity layer still uses string keys for storage; a
  # follow-up step migrates Cluster equality to be Shape-driven.
  class Shape
    attr_reader :entries

    # Build a Shape from raw path segments using the given classifier.
    def self.from_segments(segments, classifier: SegmentClassifier::DEFAULT)
      new(entries: SegmentHints.derive(segments || [], classifier))
    end

    # Build a Shape from already-derived SegmentHints entries — same input
    # PathShape.from_entries used to take. Useful when the caller already
    # walked segments once and wants to avoid a second pass.
    def self.from_entries(entries)
      new(entries: entries || [])
    end

    def initialize(entries:)
      @entries = entries
    end

    def empty?
      @entries.empty?
    end

    # Render to the placeholder form — "/users/{user_id}" etc. This is the
    # default string representation.
    def render(hints: true, canonical_dates: false, canonical_currencies: false)
      return "/" if empty?

      "/" + @entries.map { |e|
        render_entry(e, hints: hints, canonical_dates: canonical_dates,
                        canonical_currencies: canonical_currencies)
      }.join("/")
    end

    def to_s
      render
    end
    alias inspect to_s

    # Structural equality: two Shapes are equal when they render the same
    # placeholder form. /users/1 and /users/999 are the same shape even
    # though raw values differ, but /users/1 and /posts/1 are not.
    def ==(other)
      other.is_a?(Shape) && other.render == render
    end
    alias eql? ==

    def hash
      render.hash
    end

    def to_dump
      { "entries" => @entries.map { |e| e.transform_keys(&:to_s) } }
    end

    def self.from_dump(h)
      entries = (h["entries"] || []).map do |e|
        e.each_with_object({}) do |(k, v), acc|
          key = k.to_sym
          # Only :type is symbolized — :value and :hint stay as strings,
          # matching what SegmentHints.derive produces.
          acc[key] = key == :type ? v.to_sym : v
        end
      end
      new(entries: entries)
    end

    private

    def render_entry(entry, hints:, canonical_dates:, canonical_currencies:)
      return entry[:value] unless entry[:variable]

      if canonical_dates && entry[:type] == :date &&
         (canon = SegmentClassifier.canonical_date(entry[:value]))
        return canon
      end

      if canonical_currencies && entry[:type] == :currency &&
         (canon = SegmentClassifier.canonical_currency(entry[:value]))
        return canon
      end

      placeholder = if hints
                      entry[:hint] || SegmentClassifier.display_type(entry[:type])
                    else
                      SegmentClassifier.display_type(entry[:type])
                    end
      "{#{placeholder}}"
    end
  end
end
