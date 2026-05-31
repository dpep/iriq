module Iriq
  module Recognizers
    # ISO 8601 (YYYY-MM-DD), slash form (YYYY/MM/DD), and US-style
    # (M/D/YYYY) date shapes. Compact YYYYMMDD lives on the Integer
    # recognizer — it sees the digits-only input first.
    #
    # Conservative: DD/MM/YYYY is intentionally NOT recognized — from a
    # bare segment we can't tell it apart from MM/DD/YYYY.
    class Date < Recognizer
      ISO_PATTERN     = /\A\d{4}-\d{2}-\d{2}\z/.freeze
      SLASH_PATTERN   = %r{\A\d{4}/\d{2}/\d{2}\z}.freeze
      US_PATTERN      = %r{\A(\d{1,2})/(\d{1,2})/(\d{4})\z}.freeze

      def try(segment)
        has_dash  = segment.include?("-")
        has_slash = segment.include?("/")
        return nil unless has_dash || has_slash
        unless ISO_PATTERN.match?(segment) ||
               SLASH_PATTERN.match?(segment) ||
               US_PATTERN.match?(segment)
          return nil
        end

        { type: :date, confidence: 1.0, specificity: Specificity::STRUCTURED }
      end

      # Canonicalize a recognized date to ISO 8601 (YYYY-MM-DD). nil for
      # non-date / implausible-date values. Day-of-month validity (Feb 30,
      # Apr 31) deliberately not checked — out of scope for a heuristic.
      def self.canonical(value)
        return nil if value.nil?

        case value
        when ISO_PATTERN
          plausible?(value[0, 4], value[5, 2], value[8, 2]) ? value : nil
        when SLASH_PATTERN
          plausible?(value[0, 4], value[5, 2], value[8, 2]) ? value.tr("/", "-") : nil
        when US_PATTERN
          m = ::Regexp.last_match
          mm, dd, yyyy = m[1].rjust(2, "0"), m[2].rjust(2, "0"), m[3]
          plausible?(yyyy, mm, dd) ? "#{yyyy}-#{mm}-#{dd}" : nil
        end
      end

      def self.plausible?(y, m, d)
        yi = y.to_i; mi = m.to_i; di = d.to_i
        yi.between?(1900, 2100) && mi.between?(1, 12) && di.between?(1, 31)
      end
    end

    DATE = Date.new
  end
end
