module Iriq
  # The result of Corpus#observe. Lightweight value object — heavy work
  # (explanation, normalization) is deferred until you ask.
  class Observation
    attr_reader :identifier, :cluster

    def initialize(corpus:, identifier:, cluster:)
      @corpus     = corpus
      @identifier = identifier
      @cluster    = cluster
    end

    def fingerprint
      @fingerprint ||= Normalizer.normalize_identifier(@identifier)
    end

    def explanation
      @explanation ||= @corpus.explain(@identifier)
    end

    def normalize
      @corpus.normalize(@identifier)
    end
  end
end
