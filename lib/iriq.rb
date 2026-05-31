require "iriq/version"
require "iriq/errors"
require "iriq/inflector"
require "iriq/identifier"
require "iriq/parser"
require "iriq/specificity"
require "iriq/recognizer"
require "iriq/recognizers/uuid"
require "iriq/recognizers/date"
require "iriq/recognizers/integer"
require "iriq/segment_classifier"
require "iriq/segment_hints"
require "iriq/path_shape"
require "iriq/normalizer"
require "iriq/explanation"
require "iriq/trace"
require "iriq/cluster"
require "iriq/clusterer"
require "iriq/position_stats"
require "set"

require "iriq/observation"
require "iriq/registrable_domain"
require "iriq/storage"
require "iriq/corpus"
require "iriq/extractor"
require "iriq/cli"

module Iriq
  class << self
    def parse(input)
      Parser.parse(input)
    end

    def normalize(input)
      Normalizer.normalize(input)
    end

    def explain(input)
      Explanation.explain(input)
    end

    def extract(text)
      Extractor.new.extract(text)
    end
  end
end
