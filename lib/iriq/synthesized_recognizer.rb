module Iriq
  # Recognizer built dynamically from a learned-prefix pattern.
  #
  # Used by Corpus#activate_proposal to promote a RecognizerProposal
  # into a live Recognizer that the classifier ensemble consults. Same
  # shape as the built-in Recognizers — uuid, date, integer — but the
  # pattern + type are supplied at construction instead of compiled-in.
  #
  #   r = SynthesizedRecognizer.new(prefix: "ghp_", type: :ghp)
  #   r.try("ghp_abcdef123")  # → {type: :ghp, confidence: 1.0, specificity: 1.0}
  #
  # Pattern: `<prefix><[A-Za-z0-9]+>` — anchored, alphanumeric suffix
  # only. Matches the same shape PrefixUnderscoreId proposes from, so
  # round-trip (propose → activate → reinfer) reclassifies the same
  # values the proposal was derived from.
  #
  # Specificity defaults to SEMANTIC. A learned prefix is very specific
  # by construction (a distinctive literal prefix that recurred enough
  # to clear the proposal noise floor) — calling it as confident as a
  # built-in UUID is reasonable.
  class SynthesizedRecognizer < Recognizer
    attr_reader :prefix, :type, :specificity

    def self.from_proposal(proposal)
      new(prefix: proposal.prefix, type: proposal.suggested_type)
    end

    def initialize(prefix:, type:, specificity: Specificity::SEMANTIC)
      raise ArgumentError, "prefix must be a non-empty string" if prefix.nil? || prefix.empty?
      raise ArgumentError, "type must be a symbol" unless type.is_a?(Symbol)

      @prefix      = prefix
      @type        = type
      @specificity = specificity
      @pattern     = /\A#{Regexp.escape(prefix)}[A-Za-z0-9]+\z/.freeze
    end

    def try(segment)
      return nil unless segment.start_with?(@prefix) && @pattern.match?(segment)

      { type: @type, confidence: 1.0, specificity: @specificity }
    end

    def to_dump
      { "prefix" => @prefix, "type" => @type.to_s, "specificity" => @specificity }
    end

    def self.from_dump(h)
      new(
        prefix:      h["prefix"],
        type:        h["type"].to_sym,
        specificity: h.fetch("specificity", Specificity::SEMANTIC),
      )
    end
  end
end
