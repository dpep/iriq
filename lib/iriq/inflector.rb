require "set"

module Iriq
  # Singularization with a swappable adapter.
  #
  # By default uses ActiveSupport's inflector if it can be required, otherwise
  # falls back to BuiltinAdapter. Override globally:
  #
  #   Iriq::Inflector.adapter = MyAdapter   # must respond to .singularize(String)
  #
  # And reset to default with `Iriq::Inflector.reset_adapter!`.
  module Inflector
    # Vocabulary is bounded in practice; cache + cap matches the
    # SegmentClassifier strategy.
    CACHE_MAX = 10_000

    class << self
      def singularize(word)
        cache = (@cache ||= {})
        cached = cache[word]
        return cached if cached

        cache.clear if cache.size >= CACHE_MAX
        cache[word] = adapter.singularize(word)
      end

      def adapter
        @adapter ||= default_adapter
      end

      def adapter=(value)
        @adapter = value
        @cache = {} # different adapter could singularize differently
      end

      def reset_adapter!
        @adapter = nil
        @cache = {}
      end

      def default_adapter
        require "active_support/inflector"
        ActiveSupportAdapter
      rescue LoadError
        BuiltinAdapter
      end
    end

    module ActiveSupportAdapter
      def self.singularize(word)
        ::ActiveSupport::Inflector.singularize(word.to_s)
      end
    end

    # Rule-based English singularizer. Rules are ordered most-specific-first
    # and adapted from ActiveSupport's default inflections.
    module BuiltinAdapter
      IRREGULARS = {
        "people"   => "person",
        "children" => "child",
        "men"      => "man",
        "women"    => "woman",
        "mice"     => "mouse",
        "geese"    => "goose",
        "oxen"     => "ox",
        "feet"     => "foot",
        "teeth"    => "tooth",
        "lives"    => "life",
        "wives"    => "wife",
        "moves"    => "move",
        "zombies"  => "zombie",
        # latin/greek plurals that don't fit a clean suffix rule
        "indices"  => "index",
        "vertices" => "vertex",
        # -f/-fe words where the stem doesn't end in l/r/i
        "leaves"   => "leaf",
        "calves"   => "calf",
        "halves"   => "half",
        "loaves"   => "loaf",
        "hooves"   => "hoof",
      }.freeze

      UNCOUNTABLE = Set.new(%w[
        news fish sheep deer series species equipment information
        money rice jeans police data media
      ]).freeze

      # [pattern, replacement] — first match wins.
      RULES = [
        [/(quiz)zes$/i,                       '\1'],
        [/(matri|appendi)ces$/i,              '\1x'],
        [/(ox)en$/i,                          '\1'],
        [/(alias|status)(es)?$/i,             '\1'],
        [/(octop|vir)(us|i)$/i,               '\1us'],
        [/(cris|ax|test)es$/i,                '\1is'],
        [/(shoe)s$/i,                         '\1'],
        [/(bus)(es)?$/i,                      '\1'],
        [/([ml])ice$/i,                       '\1ouse'],
        [/(x|ch|ss|sh)es$/i,                  '\1'],
        [/(m)ovies$/i,                        '\1ovie'],
        [/(s)eries$/i,                        '\1eries'],
        [/([^aeiouy]|qu)ies$/i,               '\1y'],
        [/([lr])ves$/i,                       '\1f'],
        [/(tive)s$/i,                         '\1'],
        [/(hive)s$/i,                         '\1'],
        [/([^f])ves$/i,                       '\1fe'],
        [/((a)naly|(b)a|(d)iagno|(p)arenthe|(p)rogno|(s)ynop|(t)he)ses$/i, '\1sis'],
        [/([ti])a$/i,                         '\1um'],
        [/(n)ews$/i,                          '\1ews'],
        [/(o)es$/i,                           '\1'],
        [/(ss)$/i,                            '\1'],
        [/s$/i,                               ''],
      ].freeze

      def self.singularize(word)
        return word if word.nil? || word.empty?

        lower = word.downcase
        return word if UNCOUNTABLE.include?(lower)

        if (irr = IRREGULARS[lower])
          return preserve_case(word, irr)
        end

        RULES.each do |pattern, replacement|
          if word.match?(pattern)
            return word.sub(pattern, replacement)
          end
        end

        word
      end

      def self.preserve_case(original, lowered)
        if original == original.upcase
          lowered.upcase
        elsif original[0] == original[0].upcase
          lowered.sub(/\A./, &:upcase)
        else
          lowered
        end
      end
    end
  end
end
