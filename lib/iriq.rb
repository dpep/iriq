require "iriq/version"
require "iriq/errors"
require "iriq/inflector"
require "iriq/identifier"
require "iriq/parser"
require "iriq/segment_classifier"
require "iriq/segment_hints"
require "iriq/path_shape"
require "iriq/normalizer"
require "iriq/explanation"
require "iriq/cluster"
require "iriq/clusterer"
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
  end
end
