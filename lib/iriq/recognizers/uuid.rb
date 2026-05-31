module Iriq
  module Recognizers
    # RFC 4122 UUID. Shape-only — does not validate version/variant bits.
    class Uuid < Recognizer
      PATTERN = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/.freeze

      def try(segment)
        return nil unless segment.size == 36 && segment.include?("-") && PATTERN.match?(segment)

        { type: :uuid, confidence: 1.0 }
      end
    end

    UUID = Uuid.new
  end
end
