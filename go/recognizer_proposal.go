package iriq

import (
	"regexp"
	"sort"
	"strings"
)

// RecognizerProposal is a suggestion that a new Recognizer should be
// added to the system. Emitted by Corpus.ProposeRecognizers; NOT
// automatically activated — proposals carry enough evidence for a human
// to judge whether to add the Recognizer to the built-in set (or
// register it dynamically once a public Recognizer registry exists).
type RecognizerProposal struct {
	Prefix            string     // detected shape signature, e.g. "ghp_"
	SuggestedType     string     // type name suggestion if accepted, e.g. "ghp"
	Positions         []Position // every Position where the proposal matched
	Hosts             []string   // distinct hosts the proposal was seen at (sorted)
	Coverage          float64    // matching sampled observations / total sampled
	// Confidence integrates Coverage + cross-host corroboration. Single-host
	// proposals have Confidence == Coverage; each additional host adds
	// CrossHostBoostPerHost (default 0.05), capped at 1.0.
	Confidence        float64
	ObservationCount  int        // total matching observations
	SampleValues      []string   // up to 5 examples
	Strategy          string     // strategy that emitted this proposal
}

// CrossHostBoostPerHost is the per-host confidence boost beyond the first.
// A pattern seen on 10+ hosts caps out the boost; single-host patterns
// get no boost (their coverage IS their confidence).
const CrossHostBoostPerHost = 0.05

// computeConfidence applies the cross-host boost formula.
func computeConfidence(coverage float64, hostCount int) float64 {
	score := coverage + CrossHostBoostPerHost*float64(hostCount-1)
	if score > 1.0 {
		return 1.0
	}
	return score
}

// ProposalStrategy is the interface for pluggable proposal-detection
// rules. Each strategy reads from storage and returns proposals.
// Adding a new detection rule = implement Propose; register it via
// DefaultProposalStrategies.
type ProposalStrategy interface {
	Propose(s Storage, opts ProposalOptions) []RecognizerProposal
	Name() string
}

// ProposalOptions tunes what passes the noise floor. Zero values fall
// back to library defaults so callers can pass an empty struct.
type ProposalOptions struct {
	MinObservations int     // matching observations required to fire
	MinCoverage     float64 // fraction of sampled observations matching
	MinHosts        int     // distinct hosts required
}

// Defaults for ProposalOptions. Match the Ruby ProposalStrategy constants.
const (
	DefaultProposalMinObservations = 20
	DefaultProposalMinCoverage     = 0.7
	DefaultProposalMinHosts        = 1
)

func (o ProposalOptions) withDefaults() ProposalOptions {
	if o.MinObservations == 0 {
		o.MinObservations = DefaultProposalMinObservations
	}
	if o.MinCoverage == 0 {
		o.MinCoverage = DefaultProposalMinCoverage
	}
	if o.MinHosts == 0 {
		o.MinHosts = DefaultProposalMinHosts
	}
	return o
}

// PrefixUnderscoreIdStrategy detects `<prefix>_<alphanumeric>` patterns
// at slug/opaque_id positions — the GitHub PAT (`ghp_…`), Stripe customer
// ID (`cus_…`), Twilio SID-with-letter-prefix family. The alphanumeric
// suffix (no further separators) keeps real slugs (`my-cool-post`,
// `red_team_member`) from triggering false proposals.
type PrefixUnderscoreIdStrategy struct{}

var prefixUnderscoreIDPattern = regexp.MustCompile(`^([a-z]+)_([A-Za-z0-9]+)$`)

func (PrefixUnderscoreIdStrategy) Name() string { return "prefix_underscore_id" }

func (PrefixUnderscoreIdStrategy) Propose(s Storage, opts ProposalOptions) []RecognizerProposal {
	opts = opts.withDefaults()

	type accumulator struct {
		positions             map[Position]struct{}
		positionsOrdered      []Position
		hosts                 map[string]struct{}
		matchingCount         int
		positionObservations  int
		matches               []string // every match; sorted + capped at emit time
	}
	perPrefix := map[string]*accumulator{}

	s.EachPositionStats(func(pos Position, stats *PositionStats) {
		if stats == nil || !slugOrOpaqueDominant(stats) {
			return
		}
		for value, count := range stats.ValueCounts {
			m := prefixUnderscoreIDPattern.FindStringSubmatch(value)
			if m == nil {
				continue
			}
			prefix := m[1] + "_"
			acc, ok := perPrefix[prefix]
			if !ok {
				acc = &accumulator{
					positions: map[Position]struct{}{},
					hosts:     map[string]struct{}{},
				}
				perPrefix[prefix] = acc
			}
			acc.matchingCount += count
			if _, seen := acc.positions[pos]; !seen {
				acc.positions[pos] = struct{}{}
				acc.positionsOrdered = append(acc.positionsOrdered, pos)
				acc.positionObservations += stats.Total
			}
			acc.hosts[pos.Host] = struct{}{}
			acc.matches = append(acc.matches, value)
		}
	})

	var out []RecognizerProposal
	prefixes := make([]string, 0, len(perPrefix))
	for p := range perPrefix {
		prefixes = append(prefixes, p)
	}
	sort.Strings(prefixes)

	for _, prefix := range prefixes {
		acc := perPrefix[prefix]
		if acc.matchingCount < opts.MinObservations {
			continue
		}
		if len(acc.hosts) < opts.MinHosts {
			continue
		}
		coverage := float64(acc.matchingCount) / float64(acc.positionObservations)
		if coverage < opts.MinCoverage {
			continue
		}

		hostList := make([]string, 0, len(acc.hosts))
		for h := range acc.hosts {
			hostList = append(hostList, h)
		}
		sort.Strings(hostList)

		// Sort + cap to 5 so Ruby and Go produce identical samples
		// regardless of underlying map iteration order. Samples are
		// illustrative for humans; alphabetical is fine.
		samples := append([]string(nil), acc.matches...)
		sort.Strings(samples)
		if len(samples) > 5 {
			samples = samples[:5]
		}

		out = append(out, RecognizerProposal{
			Prefix:           prefix,
			SuggestedType:    strings.TrimSuffix(prefix, "_"),
			Positions:        acc.positionsOrdered,
			Hosts:            hostList,
			Coverage:         coverage,
			Confidence:       computeConfidence(coverage, len(hostList)),
			ObservationCount: acc.matchingCount,
			SampleValues:     samples,
			Strategy:         PrefixUnderscoreIdStrategy{}.Name(),
		})
	}
	// Stable rank: confidence desc, then prefix asc.
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Confidence != out[j].Confidence {
			return out[i].Confidence > out[j].Confidence
		}
		return out[i].Prefix < out[j].Prefix
	})
	return out
}

func slugOrOpaqueDominant(stats *PositionStats) bool {
	var dom SegmentType
	maxCount := 0
	for t, c := range stats.TypeCounts {
		if c > maxCount {
			maxCount = c
			dom = t
		}
	}
	return dom == TypeSlug || dom == TypeOpaqueID
}

// DefaultProposalStrategies is the built-in set Corpus.ProposeRecognizers
// uses when no explicit slice is passed.
var DefaultProposalStrategies = []ProposalStrategy{PrefixUnderscoreIdStrategy{}}
