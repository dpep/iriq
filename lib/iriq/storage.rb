require "securerandom"

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

    # Replace `path` atomically via a writer-unique temp file + rename. A
    # shared `PATH.tmp` let concurrent writers rename each other's file away
    # (ENOENT). Last writer still wins: a JSON corpus is single-writer.
    def write_atomically(path, contents)
      tmp = "#{path}.#{SecureRandom.hex(8)}.tmp"
      File.write(tmp, contents)
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end
  end
end

require "iriq/storage/memory"
