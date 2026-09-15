module Iriq
  class Error < StandardError; end
  class ParseError < Error; end
  # A corpus iriq can't use: unrecognized, from a newer iriq, or failing to
  # open, read or write. The message is `corpus PATH: reason`.
  class CorpusError < Error; end

  # An OS error in the words Rust's io::Error uses, `Permission denied (os
  # error 13)`, without Ruby's ` @ rb_sysopen - PATH` suffix.
  def self.os_error_message(error)
    "#{SystemCallError.new(nil, error.errno).message} (os error #{error.errno})"
  end
end
