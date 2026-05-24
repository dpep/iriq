module Iriq
  # Storage is the persistence layer for a Corpus. It owns every counter and
  # per-(host, prefix) frequency map; the Corpus class delegates state to it.
  #
  # Three concrete backends ship:
  #
  #   Storage::Memory   — in-memory only; matches the original behavior.
  #   Storage::Json     — Memory backend wrapped with load/save against a JSON file.
  #   Storage::Sqlite   — incremental UPSERTs against a SQLite database.
  #
  # File-extension dispatch keeps callers simple: `.json` (or anything else)
  # picks Json, `.db`/`.sqlite`/`.sqlite3` picks Sqlite.
  module Storage
    SQLITE_EXTS = %w[.db .sqlite .sqlite3].freeze

    module_function

    # Opens (or creates) a storage at `path`, picking the backend by extension.
    # If `path` is nil, returns a Memory backend.
    def open(path, classifier: SegmentClassifier::DEFAULT,
                   max_values_per_position: PositionStats::DEFAULT_MAX_VALUES)
      return Memory.new(classifier: classifier, max_values_per_position: max_values_per_position) if path.nil?

      if SQLITE_EXTS.include?(File.extname(path).downcase)
        require "iriq/storage/sqlite"
        Sqlite.open(path, classifier: classifier, max_values_per_position: max_values_per_position)
      else
        require "iriq/storage/json"
        Json.open(path, classifier: classifier, max_values_per_position: max_values_per_position)
      end
    end
  end
end

require "iriq/storage/memory"
