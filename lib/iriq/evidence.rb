module Iriq
  # Evidence is the structured substrate for explanation. Each Record
  # captures one fact about the system's reasoning: "this segment
  # classified as :integer because the Integer recognizer fired with
  # specificity TYPED", "the IPv4 type collapses to {ip} by policy",
  # "Position P is mostly variable because of corpus stats".
  #
  # Trace and Explanation are views over a list of Evidence records;
  # the structured form is what programmatic consumers (test assertions,
  # PR-diff annotators, downstream tooling) should build on. Human note
  # strings emitted by Trace are derived from Evidence payloads, so
  # adding a new note kind starts with adding a new Evidence shape.
  #
  # Two axes:
  #
  #   subject_kind ∈ {:segment, :position, :cluster}
  #     What this Evidence is about. Today most Evidence is :segment
  #     (per-segment classification facts). :position and :cluster
  #     Evidence become load-bearing once corpus-informed Trace lands
  #     in a follow-up step.
  #
  #   source ∈ {:lexical, :recognizer, :corpus, :neighbor, :policy}
  #     What kind of fact is being asserted.
  #       :lexical    — pure shape match (e.g. "matches DATE_RE")
  #       :recognizer — a named Recognizer fired with confidence/specificity
  #       :corpus     — aggregated counts/distributions support this
  #       :neighbor   — adjacent context informed this (prior literal,
  #                     param name hint)
  #       :policy     — a normalization policy applied (ip umbrella
  #                     collapse, canonical date, currency upcase)
  module Evidence
    SUBJECT_KINDS = %i[segment position cluster].freeze
    SOURCES       = %i[lexical recognizer corpus neighbor policy].freeze

    # A single Evidence fact.
    #
    #   subject_kind — :segment | :position | :cluster
    #   subject      — kind-specific identity:
    #                    :segment  → { index:, value: }
    #                    :position → Iriq::Position
    #                    :cluster  → cluster key (string)
    #   source       — :lexical | :recognizer | :corpus | :neighbor | :policy
    #   payload      — source-and-kind-specific structured data
    #   weight       — optional float in [0,1] — contribution to the
    #                  ultimate decision. Set when scoring is meaningful;
    #                  nil otherwise.
    #   notes        — optional human-readable strings. Trace renders
    #                  these directly; programmatic consumers can ignore.
    class Record
      attr_reader :subject_kind, :subject, :source, :payload, :weight, :notes

      def initialize(subject_kind:, subject:, source:, payload:, weight: nil, notes: [])
        unless SUBJECT_KINDS.include?(subject_kind)
          raise ArgumentError, "subject_kind must be one of #{SUBJECT_KINDS.inspect}"
        end
        unless SOURCES.include?(source)
          raise ArgumentError, "source must be one of #{SOURCES.inspect}"
        end

        @subject_kind = subject_kind
        @subject      = subject
        @source       = source
        @payload      = payload || {}
        @weight       = weight
        @notes        = notes || []
      end

      def to_h
        {
          subject_kind: @subject_kind,
          subject:      subject_serialized,
          source:       @source,
          payload:      @payload,
          weight:       @weight,
          notes:        @notes,
        }.compact
      end

      private

      def subject_serialized
        return @subject.to_h if @subject.respond_to?(:to_h) && !@subject.is_a?(Hash)
        @subject
      end
    end

    module_function

    # Factories so call sites don't have to repeat subject_kind:.
    def segment(index:, value:, source:, payload:, weight: nil, notes: [])
      Record.new(
        subject_kind: :segment,
        subject:      { index: index, value: value },
        source:       source, payload: payload, weight: weight, notes: notes,
      )
    end

    def position(position:, source:, payload:, weight: nil, notes: [])
      Record.new(
        subject_kind: :position,
        subject:      position,
        source:       source, payload: payload, weight: weight, notes: notes,
      )
    end

    def cluster(key:, source:, payload:, weight: nil, notes: [])
      Record.new(
        subject_kind: :cluster,
        subject:      key,
        source:       source, payload: payload, weight: weight, notes: notes,
      )
    end
  end
end
