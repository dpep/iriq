require "sqlite3"

module Iriq
  module Storage
    # Sqlite is the incremental-write backend. Each observation translates
    # to a handful of UPSERTs against a long-lived connection; nothing is
    # materialized in memory beyond what reads explicitly ask for.
    #
    # WAL journaling lets multiple processes observe against the same file
    # concurrently — the writer is serialized, readers are not blocked, and
    # the existing `iriq --corpus c.db <url>` pattern works without a flock
    # at the application layer.
    class Sqlite
      SCHEMA_VERSION = 1

      SCHEMA = <<~SQL.freeze
        CREATE TABLE IF NOT EXISTS meta (
          key   TEXT PRIMARY KEY,
          value TEXT
        );
        CREATE TABLE IF NOT EXISTS host_counts (
          host  TEXT PRIMARY KEY,
          count INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS path_length_counts (
          length INTEGER PRIMARY KEY,
          count  INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS raw_shape_counts (
          shape TEXT PRIMARY KEY,
          count INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS fingerprint_counts (
          shape TEXT PRIMARY KEY,
          count INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS position_stats (
          host   TEXT NOT NULL,
          prefix TEXT NOT NULL,
          total  INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (host, prefix)
        );
        CREATE TABLE IF NOT EXISTS position_values (
          host   TEXT NOT NULL,
          prefix TEXT NOT NULL,
          value  TEXT NOT NULL,
          count  INTEGER NOT NULL,
          PRIMARY KEY (host, prefix, value)
        );
        CREATE TABLE IF NOT EXISTS position_types (
          host   TEXT NOT NULL,
          prefix TEXT NOT NULL,
          type   TEXT NOT NULL,
          count  INTEGER NOT NULL,
          PRIMARY KEY (host, prefix, type)
        );
        CREATE TABLE IF NOT EXISTS clusters (
          key    TEXT PRIMARY KEY,
          host   TEXT,
          scheme TEXT,
          shape  TEXT,
          count  INTEGER NOT NULL DEFAULT 0,
          ord    INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS cluster_examples (
          cluster_key TEXT NOT NULL,
          position    INTEGER NOT NULL,
          canonical   TEXT NOT NULL,
          PRIMARY KEY (cluster_key, position)
        );
        CREATE TABLE IF NOT EXISTS cluster_segments (
          cluster_key TEXT NOT NULL,
          position    INTEGER NOT NULL,
          value       TEXT NOT NULL,
          count       INTEGER NOT NULL,
          PRIMARY KEY (cluster_key, position, value)
        );
      SQL

      attr_reader :path, :max_values_per_position

      def self.open(path, classifier: SegmentClassifier::DEFAULT,
                          max_values_per_position: PositionStats::DEFAULT_MAX_VALUES)
        new(path: path, classifier: classifier, max_values_per_position: max_values_per_position).tap(&:setup!)
      end

      def initialize(path:, classifier: SegmentClassifier::DEFAULT,
                     max_values_per_position: PositionStats::DEFAULT_MAX_VALUES)
        @path                    = path
        @classifier              = classifier
        @max_values_per_position = max_values_per_position
        @db                      = SQLite3::Database.new(path)
        # busy_timeout MUST come first: other PRAGMAs (journal_mode in
        # particular) can themselves block on the write lock under
        # concurrent open, and without busy_timeout set they fail
        # immediately with SQLITE_BUSY.
        @db.execute("PRAGMA busy_timeout = 30000")
        @db.execute("PRAGMA journal_mode = WAL")
        @db.execute("PRAGMA synchronous = NORMAL")
        @db.execute("PRAGMA foreign_keys = ON")
        @in_batch = false
      end

      def setup!
        @db.execute_batch(SCHEMA)
        existing = @db.get_first_value("SELECT value FROM meta WHERE key = 'schema_version'")
        if existing.nil?
          @db.execute("INSERT INTO meta (key, value) VALUES ('schema_version', ?)", SCHEMA_VERSION.to_s)
          @db.execute("INSERT INTO meta (key, value) VALUES ('max_values_per_position', ?)",
                      @max_values_per_position.to_s)
        else
          @max_values_per_position = (@db.get_first_value(
            "SELECT value FROM meta WHERE key = 'max_values_per_position'"
          ) || @max_values_per_position).to_i
        end
        self
      end

      def transaction
        # While inside an outer batch, observe()-time transactions become
        # no-ops — the outer batch wraps everything in one txn for speed.
        return yield(self) if @in_batch

        @db.transaction
        yield self
        @db.commit
      rescue
        @db.rollback rescue nil
        raise
      end

      # Wrap many observations in a single transaction. Cuts SQLite write
      # overhead from O(observations) fsyncs to O(1).
      def batch
        return yield if @in_batch

        @in_batch = true
        @db.transaction
        begin
          yield
          @db.commit
        rescue
          @db.rollback rescue nil
          raise
        ensure
          @in_batch = false
        end
      end

      # Saving is automatic — incremental UPSERTs hit disk on commit. flush
      # makes that explicit; close releases the connection.
      def flush; end

      def save(_path = nil)
        # Already persisted. Provided for parity with the JSON backend.
      end

      def close
        # Checkpoint + truncate the WAL so the .db-wal sidecar doesn't grow
        # unbounded across long-lived `iriq --corpus c.db` sessions.
        @db.execute("PRAGMA wal_checkpoint(TRUNCATE)") rescue nil
        @db.close
      end

      # --- Increments -------------------------------------------------------

      def increment_host(host)
        return unless host

        @db.execute(<<~SQL, host)
          INSERT INTO host_counts (host, count) VALUES (?, 1)
          ON CONFLICT(host) DO UPDATE SET count = count + 1
        SQL
      end

      def increment_path_length(length)
        @db.execute(<<~SQL, length)
          INSERT INTO path_length_counts (length, count) VALUES (?, 1)
          ON CONFLICT(length) DO UPDATE SET count = count + 1
        SQL
      end

      def increment_raw_shape(shape)
        upsert_shape("raw_shape_counts", shape)
      end

      def increment_fingerprint(shape)
        upsert_shape("fingerprint_counts", shape)
      end

      def observe_position(host, prefix, value, type)
        host ||= ""
        @db.execute(<<~SQL, [host, prefix])
          INSERT INTO position_stats (host, prefix, total) VALUES (?, ?, 1)
          ON CONFLICT(host, prefix) DO UPDATE SET total = total + 1
        SQL

        # Type counts are unbounded — always upsert.
        @db.execute(<<~SQL, [host, prefix, type.to_s])
          INSERT INTO position_types (host, prefix, type, count) VALUES (?, ?, ?, 1)
          ON CONFLICT(host, prefix, type) DO UPDATE SET count = count + 1
        SQL

        # Value counts are capped at max_values_per_position. If the value
        # already exists, increment it; otherwise insert only when
        # cardinality is below the cap. Two-step rather than ON CONFLICT
        # because we need to enforce the cap on insert.
        @db.execute(<<~SQL, [host, prefix, value])
          UPDATE position_values SET count = count + 1
          WHERE host = ? AND prefix = ? AND value = ?
        SQL
        if @db.changes.zero?
          card = @db.get_first_value(
            "SELECT COUNT(*) FROM position_values WHERE host = ? AND prefix = ?",
            [host, prefix],
          )
          if card < @max_values_per_position
            @db.execute(
              "INSERT INTO position_values (host, prefix, value, count) VALUES (?, ?, ?, 1)",
              [host, prefix, value],
            )
          end
        end
      end

      def add_to_cluster(key, host, scheme, shape, identifier)
        # Insert the cluster row if new (with a monotonic ord for stable
        # iteration), then bump its count.
        @db.execute(<<~SQL, [key, host, scheme, shape])
          INSERT INTO clusters (key, host, scheme, shape, count, ord)
          VALUES (?, ?, ?, ?, 1, (SELECT COALESCE(MAX(ord), 0) + 1 FROM clusters))
          ON CONFLICT(key) DO UPDATE SET count = count + 1
        SQL

        # Examples — capped at Cluster::MAX_EXAMPLES.
        examples_count = @db.get_first_value(
          "SELECT COUNT(*) FROM cluster_examples WHERE cluster_key = ?", [key],
        )
        if examples_count < Cluster::MAX_EXAMPLES
          @db.execute(<<~SQL, [key, examples_count, identifier.canonical])
            INSERT INTO cluster_examples (cluster_key, position, canonical)
            VALUES (?, ?, ?)
          SQL
        end

        # Per-position segment counts — uncapped.
        identifier.path_segments.each_with_index do |seg, i|
          @db.execute(<<~SQL, [key, i, seg])
            INSERT INTO cluster_segments (cluster_key, position, value, count) VALUES (?, ?, ?, 1)
            ON CONFLICT(cluster_key, position, value) DO UPDATE SET count = count + 1
          SQL
        end

        load_cluster(key)
      end

      # --- Reads ------------------------------------------------------------

      def host_counts
        rows_to_count_hash("host_counts", "host")
      end

      def path_length_counts
        h = Hash.new(0)
        @db.execute("SELECT length, count FROM path_length_counts") { |r| h[r[0]] = r[1] }
        h
      end

      def raw_shape_counts
        rows_to_count_hash("raw_shape_counts", "shape")
      end

      def fingerprint_counts
        rows_to_count_hash("fingerprint_counts", "shape")
      end

      def position_stats(host, prefix)
        host ||= ""
        total = @db.get_first_value(
          "SELECT total FROM position_stats WHERE host = ? AND prefix = ?", [host, prefix],
        )
        return nil if total.nil?

        stats = PositionStats.new(max_values: @max_values_per_position)
        stats.instance_variable_set(:@total, total)

        vc = Hash.new(0)
        @db.execute(
          "SELECT value, count FROM position_values WHERE host = ? AND prefix = ?", [host, prefix]
        ) { |r| vc[r[0]] = r[1] }
        stats.instance_variable_set(:@value_counts, vc)

        tc = Hash.new(0)
        @db.execute(
          "SELECT type, count FROM position_types WHERE host = ? AND prefix = ?", [host, prefix]
        ) { |r| tc[r[0].to_sym] = r[1] }
        stats.instance_variable_set(:@type_counts, tc)

        stats
      end

      def each_position_stats
        seen = []
        @db.execute("SELECT DISTINCT host, prefix FROM position_stats ORDER BY ROWID") do |row|
          seen << row
        end
        seen.each { |host, prefix| yield [host, prefix], position_stats(host, prefix) }
      end

      def clusters
        out = []
        @db.execute("SELECT key FROM clusters ORDER BY ord") do |row|
          out << load_cluster(row[0])
        end
        out
      end

      def cluster_size
        @db.get_first_value("SELECT COUNT(*) FROM clusters")
      end

      private

      def upsert_shape(table, shape)
        @db.execute(<<~SQL, shape)
          INSERT INTO #{table} (shape, count) VALUES (?, 1)
          ON CONFLICT(shape) DO UPDATE SET count = count + 1
        SQL
      end

      def rows_to_count_hash(table, key_col)
        h = Hash.new(0)
        @db.execute("SELECT #{key_col}, count FROM #{table}") { |r| h[r[0]] = r[1] }
        h
      end

      def load_cluster(key)
        row = @db.get_first_row(
          "SELECT key, host, scheme, shape, count FROM clusters WHERE key = ?", [key],
        )
        return nil unless row

        c = Cluster.new(key: row[0], host: row[1], scheme: row[2], shape: row[3])
        c.instance_variable_set(:@count, row[4])

        examples = []
        @db.execute(
          "SELECT canonical FROM cluster_examples WHERE cluster_key = ? ORDER BY position", [key]
        ) { |r| examples << Parser.parse(r[0]) }
        c.instance_variable_set(:@examples, examples)

        seg_counts = []
        @db.execute(
          "SELECT position, value, count FROM cluster_segments WHERE cluster_key = ? ORDER BY position",
          [key],
        ) do |r|
          pos = r[0]
          seg_counts[pos] ||= Hash.new(0)
          seg_counts[pos][r[1]] = r[2]
        end
        c.instance_variable_set(:@segment_counts, seg_counts)

        c
      end
    end
  end
end
