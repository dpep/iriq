require "set"

module Iriq
  # A suggestion that a new Recognizer should be added to the system.
  #
  # Emitted by Corpus#propose_recognizers. NOT automatically activated —
  # proposals carry enough evidence for a human to judge whether to add
  # the Recognizer to the built-in set (or, later, to register it
  # dynamically via a public Recognizer registry).
  #
  #   prefix             — the detected shape signature (e.g. "ghp_")
  #   suggested_type     — Symbol name we'd register the Recognizer under
  #                        if accepted (e.g. :ghp)
  #   positions          — every Position where the proposal matched
  #   hosts              — distinct hosts the proposal was seen at; a high
  #                        count is strong evidence the pattern isn't
  #                        host-local
  #   coverage           — fraction of sampled observations at affected
  #                        Positions matching the proposal pattern
  #   observation_count  — total matching observations across positions
  #   sample_values      — up to 5 example matches, for the human reviewer
  #   strategy           — the ProposalStrategy that emitted this record
  class RecognizerProposal
    attr_reader :prefix, :suggested_type, :positions, :hosts,
                :coverage, :confidence, :observation_count,
                :sample_values, :strategy

    def initialize(prefix:, suggested_type:, positions:, hosts:,
                   coverage:, observation_count:, sample_values:,
                   strategy:, confidence: nil)
      @prefix            = prefix
      @suggested_type    = suggested_type
      @positions         = positions.freeze
      @hosts             = hosts.is_a?(Set) ? hosts.dup.freeze : Set.new(hosts).freeze
      @coverage          = coverage
      @observation_count = observation_count
      @sample_values     = sample_values.freeze
      @strategy          = strategy
      @confidence        = confidence.nil? ? compute_confidence : confidence
    end

    def to_h
      {
        prefix:            @prefix,
        suggested_type:    @suggested_type,
        positions:         @positions.map(&:to_h),
        hosts:             @hosts.to_a.sort,
        coverage:          @coverage,
        confidence:        @confidence,
        observation_count: @observation_count,
        sample_values:     @sample_values,
        strategy:          @strategy,
      }
    end

    private

    # Confidence = coverage + linear cross-host boost, capped at 1.0.
    # Single-host proposals get their raw coverage as confidence (no
    # boost). Each additional host adds CROSS_HOST_BOOST_PER_HOST to
    # the score. A proposal supported by ~10 distinct hosts caps out
    # regardless of raw coverage; below that, both signals compose.
    def compute_confidence
      boost = (@hosts.size - 1) * ProposalStrategy::CROSS_HOST_BOOST_PER_HOST
      score = @coverage + boost
      score > 1.0 ? 1.0 : score
    end
  end

  # Pluggable proposal-detection strategies. Each strategy.propose(storage, **opts)
  # returns an array of RecognizerProposal. Adding a new detection rule =
  # add a class with #propose; register it via DEFAULTS.
  module ProposalStrategy
    # Default minimum total matching observations across positions before
    # we'll emit a proposal. Below this the signal is too noisy.
    DEFAULT_MIN_OBSERVATIONS = 20
    # Fraction of sampled observations at affected Positions that must
    # match the proposal pattern.
    DEFAULT_MIN_COVERAGE     = 0.7
    # Minimum number of distinct hosts the proposal must appear at. For
    # single-host corpora this defaults to 1; bumping to 2+ promotes
    # cross-host patterns over host-local ones.
    DEFAULT_MIN_HOSTS        = 1
    # Confidence boost added per additional host beyond the first. A
    # pattern seen on 10+ hosts caps out the boost (+0.45 ≈ 1.0 when
    # combined with any reasonable coverage); single-host patterns get
    # no boost (their coverage IS their confidence).
    CROSS_HOST_BOOST_PER_HOST = 0.05

    # Detects `<prefix>_<alphanumeric>` patterns at slug/opaque_id
    # positions — the GitHub PAT (`ghp_…`), Stripe customer ID (`cus_…`),
    # AWS-style (`sk_test_…` — partial match), Twilio SID-with-letter-
    # prefix family. Restricting the suffix to alphanumeric (no further
    # separators) keeps real slugs (`my-cool-post`, `red_team_member`)
    # from triggering false proposals.
    class PrefixUnderscoreId
      PATTERN = /\A([a-z]+)_([A-Za-z0-9]+)\z/.freeze
      NAME    = :prefix_underscore_id

      def propose(storage,
                  min_observations: DEFAULT_MIN_OBSERVATIONS,
                  min_coverage:     DEFAULT_MIN_COVERAGE,
                  min_hosts:        DEFAULT_MIN_HOSTS)
        per_prefix = Hash.new { |h, k| h[k] = empty_accumulator }

        storage.each_position_stats do |position, stats|
          next unless slug_or_opaque?(stats)

          stats.value_counts.each do |value, count|
            m = PATTERN.match(value) or next
            prefix = "#{m[1]}_"
            acc = per_prefix[prefix]
            acc[:matching_count] += count
            acc[:position_observations] += stats.total unless acc[:positions].include?(position)
            acc[:positions] << position
            acc[:hosts] << position.host
            # Collect every match; we'll sort + cap to a stable top-N at
            # emission time so Ruby and Rust produce identical samples
            # regardless of underlying Hash / map iteration order.
            acc[:matches] << value
          end
        end

        per_prefix.filter_map { |prefix, acc|
          next nil if acc[:matching_count] < min_observations
          next nil if acc[:hosts].size < min_hosts

          coverage = acc[:matching_count].to_f / acc[:position_observations]
          next nil if coverage < min_coverage

          RecognizerProposal.new(
            prefix:            prefix,
            suggested_type:    prefix.chomp("_").to_sym,
            positions:         acc[:positions].to_a,
            hosts:             acc[:hosts],
            coverage:          coverage,
            observation_count: acc[:matching_count],
            # Sort + cap to 5 so Ruby and Rust produce identical samples
            # regardless of underlying Hash / map iteration order. The
            # samples are illustrative for humans; alphabetical is fine.
            sample_values:     acc[:matches].sort.first(5),
            strategy:          NAME,
          )
        }.sort_by { |p| [-p.confidence, p.prefix] }
      end

      private

      def empty_accumulator
        {
          positions:             Set.new,
          hosts:                 Set.new,
          matching_count:        0,
          position_observations: 0,
          matches:               [],
        }
      end

      def slug_or_opaque?(stats)
        dom = stats.type_counts.max_by { |_, c| c }&.first
        dom == :slug || dom == :opaque_id
      end
    end

    DEFAULTS = [PrefixUnderscoreId.new].freeze
  end
end
