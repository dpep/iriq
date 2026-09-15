require "json"

module Iriq
  module Storage
    # Json wraps Memory with load-from-file at open and save-to-file at close.
    # Same JSON shape as the pre-Storage release, so files round-trip across
    # versions.
    class Json < Memory
      attr_reader :path

      def initialize(path: nil, **opts)
        super(**opts)
        @path = path
      end

      def self.open(path, **opts)
        s = new(path: path, **opts)
        s.load!(path) if File.exist?(path) && File.size(path).positive?
        s
      end

      # Refuses (Iriq::CorpusError) anything that isn't a corpus dump, so a
      # mistyped --corpus path can't overwrite an unrelated JSON file: it must
      # be an object with at least one corpus key, or `{}`.
      def load!(path)
        data = File.read(path)
        return self if data.empty?

        dump = begin
          JSON.parse(data)
        rescue JSON::ParserError
          raise CorpusError, "#{path} is not valid JSON; refusing to use it as a corpus"
        end
        unless dump.is_a?(Hash) && (dump.empty? || dump.keys.intersect?(DUMP_KEYS))
          raise CorpusError, "#{path} is not an iriq corpus (no recognized keys); refusing to use it"
        end

        load_dump!(dump)
        @path = path
        self
      end

      # save writes atomically (unique tmp + rename). Defaults to the path
      # passed at open(); pass an explicit path to write elsewhere.
      def save(path = nil)
        target = path || @path
        raise ArgumentError, "no path provided" unless target

        Storage.write_atomically(target, JSON.generate(to_dump))
      end
    end
  end
end
