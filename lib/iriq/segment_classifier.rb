module Iriq
  # Heuristic classifier for individual path segments and query values.
  #
  # Returns a symbol from the known TYPES set. Order matters: the first
  # matching rule wins.
  class SegmentClassifier
    TYPES = %i[literal integer_id uuid date timestamp hash slug opaque_id].freeze

    UUID_RE      = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/.freeze
    INTEGER_RE   = /\A\d+\z/.freeze
    DATE_RE      = /\A\d{4}-\d{2}-\d{2}\z/.freeze
    ISO_TIME_RE  = /\A\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+\-]\d{2}:?\d{2})?\z/.freeze
    HASH_RE      = /\A\h{32,}\z/.freeze
    SLUG_RE      = /\A[a-z0-9]+(?:[-_][a-z0-9]+)+\z/.freeze
    LITERAL_RE   = /\A[\p{L}][\p{L}\p{M}_]*\z/u.freeze
    OPAQUE_RE    = /\A[A-Za-z0-9_\-.~]{4,}\z/.freeze

    # Plausible UNIX timestamps (10 digit seconds or 13 digit ms) from
    # roughly 2001 onward.
    TS_SECONDS_RANGE = 1_000_000_000..9_999_999_999
    TS_MILLIS_RANGE  = 1_000_000_000_000..9_999_999_999_999

    def classify(segment)
      return :literal if segment.nil? || segment.empty?

      case segment
      when UUID_RE     then :uuid
      when DATE_RE     then :date
      when ISO_TIME_RE then :timestamp
      when INTEGER_RE  then classify_integer(segment)
      when HASH_RE     then :hash
      when SLUG_RE     then :slug
      when LITERAL_RE  then :literal
      when OPAQUE_RE   then :opaque_id
      else :literal
      end
    end

    # Anything except :literal is considered variable for shape/explain.
    def variable?(type)
      type != :literal
    end

    private

    def classify_integer(segment)
      n = segment.to_i
      return :timestamp if TS_MILLIS_RANGE.cover?(n)
      return :timestamp if TS_SECONDS_RANGE.cover?(n)

      :integer_id
    end
  end
end
