module Iriq
  class Error < StandardError; end
  class ParseError < Error; end
  # A corpus file iriq refuses to open (unrecognized, or from a newer iriq).
  class CorpusError < Error; end
end
