module Iriq
  module Recognizers
    # Base-10 integer. Also returns :timestamp for plausible UNIX seconds /
    # millis ranges, and :date for plausible YYYYMMDD compact dates — these
    # share the digit-only lexical shape, and we want the most specific type.
    class Integer < Recognizer
      PATTERN              = /\A\d+\z/.freeze
      COMPACT_DATE_PATTERN = /\A\d{8}\z/.freeze
      TS_SECONDS_RANGE     = 1_000_000_000..9_999_999_999
      TS_MILLIS_RANGE      = 1_000_000_000_000..9_999_999_999_999

      def try(segment)
        first  = segment.getbyte(0)
        digit0 = first && first >= 0x30 && first <= 0x39
        return nil unless digit0 && PATTERN.match?(segment)

        n = segment.to_i
        if TS_MILLIS_RANGE.cover?(n) || TS_SECONDS_RANGE.cover?(n)
          return { type: :timestamp, confidence: 1.0, specificity: Specificity::BOUNDED }
        end

        if COMPACT_DATE_PATTERN.match?(segment)
          y = segment[0, 4].to_i
          m = segment[4, 2].to_i
          d = segment[6, 2].to_i
          if y.between?(1900, 2100) && m.between?(1, 12) && d.between?(1, 31)
            return { type: :date, confidence: 1.0, specificity: Specificity::STRUCTURED }
          end
        end

        { type: :integer, confidence: 1.0, specificity: Specificity::TYPED }
      end
    end

    INTEGER = Integer.new
  end
end
