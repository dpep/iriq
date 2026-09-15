module Iriq
  # The result of Corpus#observe. Lightweight value object — heavy work
  # (cluster load, explanation, normalization) is deferred until you ask.
  class Observation
    attr_reader :identifier

    def initialize(corpus:, identifier:, cluster_key:)
      @corpus      = corpus
      @identifier  = identifier
      @cluster_key = cluster_key
    end

    # The cluster as it stands when first read; observing doesn't load it.
    def cluster
      @cluster ||= @corpus.storage.cluster_for(@cluster_key)
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
