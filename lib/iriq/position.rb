module Iriq
  # A typed slot in a host's URL structure.
  #
  # Two observations occupy the same Position when (host, scope, locator)
  # match exactly. Position is the keying type used by Storage for
  # frequency tables and by Cluster for per-slot inference.
  #
  # host    — the EFFECTIVE host per Corpus#host_strategy. Observations of
  #           api.foo.com and app.foo.com under :registrable share the
  #           same Position. The original host stays on the Identifier.
  # scope   — :path or :query.
  # locator — for :path, the typed prefix built up to this slot, e.g.
  #           "/orgs/{opaque_id}/users" for the integer slot in
  #           /orgs/abc/users/123. (Variable segments render as their
  #           hint or display-type, so the prefix groups across observations
  #           regardless of the specific IDs seen.)
  #         — for :query, the ?key= parameter name.
  #
  # Position implements value equality and is safe to use as a Hash key.
  class Position
    SCOPES = %i[path query].freeze

    attr_reader :host, :scope, :locator

    def self.path(host:, prefix:)
      new(host: host, scope: :path, locator: prefix)
    end

    def self.query(host:, name:)
      new(host: host, scope: :query, locator: name)
    end

    def initialize(host:, scope:, locator:)
      raise ArgumentError, "scope must be one of #{SCOPES.inspect}" unless SCOPES.include?(scope)

      @host    = host
      @scope   = scope
      @locator = locator
    end

    def path?;  @scope == :path;  end
    def query?; @scope == :query; end

    def ==(other)
      other.is_a?(Position) &&
        other.host == @host &&
        other.scope == @scope &&
        other.locator == @locator
    end
    alias eql? ==

    def hash
      [@host, @scope, @locator].hash
    end

    def to_h
      { host: @host, scope: @scope, locator: @locator }
    end

    def to_s
      "Position(#{@host.inspect}, #{@scope}, #{@locator.inspect})"
    end
    alias inspect to_s

    # Serialized form used by JSON / SQLite storage. Scope is emitted as
    # a string for cross-runtime compatibility.
    def to_dump
      { "host" => @host, "scope" => @scope.to_s, "locator" => @locator }
    end

    def self.from_dump(h)
      new(host: h["host"], scope: h["scope"].to_sym, locator: h["locator"])
    end
  end
end
