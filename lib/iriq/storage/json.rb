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

      def load!(path)
        data = File.read(path)
        return self if data.empty?

        load_dump!(JSON.parse(data))
        @path = path
        self
      end

      # save writes atomically (tmp + rename). Defaults to the path passed at
      # open(); pass an explicit path to write elsewhere.
      def save(path = nil)
        target = path || @path
        raise ArgumentError, "no path provided" unless target

        tmp = "#{target}.tmp"
        File.write(tmp, JSON.generate(to_dump))
        File.rename(tmp, target)
      end
    end
  end
end
