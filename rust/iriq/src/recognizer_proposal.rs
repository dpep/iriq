use crate::classifier::SegmentType;
use crate::position::Position;
use crate::position_stats::PositionStats;
use crate::storage::Storage;
use once_cell::sync::Lazy;
use regex::Regex;
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone)]
pub struct RecognizerProposal {
    pub prefix: String,
    pub suggested_type: String,
    pub positions: Vec<Position>,
    pub hosts: Vec<String>,
    pub coverage: f64,
    pub confidence: f64,
    pub observation_count: usize,
    pub sample_values: Vec<String>,
    pub strategy: String,
}

const CROSS_HOST_BOOST_PER_HOST: f64 = 0.05;

fn compute_confidence(coverage: f64, host_count: usize) -> f64 {
    let score = coverage + CROSS_HOST_BOOST_PER_HOST * (host_count.saturating_sub(1) as f64);
    score.min(1.0)
}

#[derive(Debug, Clone, Copy, Default)]
pub struct ProposalOptions {
    pub min_observations: usize,
    pub min_coverage: f64,
    pub min_hosts: usize,
}

pub const DEFAULT_PROPOSAL_MIN_OBSERVATIONS: usize = 20;
pub const DEFAULT_PROPOSAL_MIN_COVERAGE: f64 = 0.7;
pub const DEFAULT_PROPOSAL_MIN_HOSTS: usize = 1;

fn with_defaults(mut o: ProposalOptions) -> ProposalOptions {
    if o.min_observations == 0 {
        o.min_observations = DEFAULT_PROPOSAL_MIN_OBSERVATIONS;
    }
    if o.min_coverage == 0.0 {
        o.min_coverage = DEFAULT_PROPOSAL_MIN_COVERAGE;
    }
    if o.min_hosts == 0 {
        o.min_hosts = DEFAULT_PROPOSAL_MIN_HOSTS;
    }
    o
}

static PREFIX_UNDERSCORE_ID_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^([a-z]+)_([A-Za-z0-9]+)$").unwrap());

struct Accumulator {
    positions: HashSet<Position>,
    positions_ordered: Vec<Position>,
    hosts: HashSet<String>,
    matching_count: usize,
    position_observations: usize,
    matches: Vec<String>,
}

pub fn propose_recognizers(
    storage: &dyn Storage,
    opts: ProposalOptions,
) -> Vec<RecognizerProposal> {
    let opts = with_defaults(opts);
    let mut per_prefix: HashMap<String, Accumulator> = HashMap::new();

    let mut visitor = |pos: &Position, stats: &PositionStats| {
        if !slug_or_opaque_dominant(stats) {
            return;
        }
        for (value, count) in &stats.value_counts {
            let Some(caps) = PREFIX_UNDERSCORE_ID_RE.captures(value) else {
                continue;
            };
            let prefix = format!("{}_", caps.get(1).unwrap().as_str());
            let acc = per_prefix.entry(prefix).or_insert_with(|| Accumulator {
                positions: HashSet::new(),
                positions_ordered: Vec::new(),
                hosts: HashSet::new(),
                matching_count: 0,
                position_observations: 0,
                matches: Vec::new(),
            });
            acc.matching_count += count;
            if acc.positions.insert(pos.clone()) {
                acc.positions_ordered.push(pos.clone());
                acc.position_observations += stats.total;
            }
            acc.hosts.insert(pos.host.clone());
            acc.matches.push(value.clone());
        }
    };
    storage.each_position_stats(&mut visitor);

    let mut prefixes: Vec<String> = per_prefix.keys().cloned().collect();
    prefixes.sort();

    let mut out: Vec<RecognizerProposal> = Vec::new();
    for prefix in prefixes {
        let acc = per_prefix.get(&prefix).unwrap();
        if acc.matching_count < opts.min_observations {
            continue;
        }
        if acc.hosts.len() < opts.min_hosts {
            continue;
        }
        let coverage = (acc.matching_count as f64) / (acc.position_observations as f64);
        if coverage < opts.min_coverage {
            continue;
        }
        let mut hosts: Vec<String> = acc.hosts.iter().cloned().collect();
        hosts.sort();
        let mut samples: Vec<String> = acc.matches.clone();
        samples.sort();
        samples.truncate(5);

        let suggested = prefix.trim_end_matches('_').to_string();
        out.push(RecognizerProposal {
            prefix: prefix.clone(),
            suggested_type: suggested,
            positions: acc.positions_ordered.clone(),
            hosts: hosts.clone(),
            coverage,
            confidence: compute_confidence(coverage, hosts.len()),
            observation_count: acc.matching_count,
            sample_values: samples,
            strategy: "prefix_underscore_id".to_string(),
        });
    }

    out.sort_by(|a, b| {
        b.confidence
            .partial_cmp(&a.confidence)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.prefix.cmp(&b.prefix))
    });
    out
}

fn slug_or_opaque_dominant(stats: &PositionStats) -> bool {
    let mut dom = SegmentType::Literal;
    let mut max = 0usize;
    for (&t, &c) in &stats.type_counts {
        if c > max {
            max = c;
            dom = t;
        }
    }
    dom == SegmentType::Slug || dom == SegmentType::OpaqueId
}
