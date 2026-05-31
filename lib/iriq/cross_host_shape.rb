require "set"

module Iriq
  # A route shape that recurs across multiple hosts.
  #
  # Emitted by Corpus#cross_host_shapes. The shape string ("/users/{user_id}")
  # is the cluster's rendered placeholder form; two clusters with the same
  # shape but different hosts coalesce into one CrossHostShape record.
  #
  # A shape appearing at N hosts is strong evidence of a semantic pattern
  # rather than a host-local quirk — independent hosts are unlikely to
  # invent the same `/users/{integer}` structure by accident. Future work
  # can feed this signal into proposal confidence and corpus-informed
  # normalization (raise weight when a Shape has cross-host support).
  class CrossHostShape
    attr_reader :shape, :hosts, :observation_count

    def initialize(shape:, hosts:, observation_count:)
      @shape             = shape
      @hosts             = hosts.is_a?(Set) ? hosts.dup.freeze : Set.new(hosts).freeze
      @observation_count = observation_count
    end

    def host_count
      @hosts.size
    end

    def to_h
      {
        shape:             @shape,
        hosts:             @hosts.to_a.sort,
        host_count:        host_count,
        observation_count: @observation_count,
      }
    end
  end
end
