use crate::corpus::Corpus;
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct CrossHostShape {
    pub shape: String,
    pub hosts: Vec<String>,
    pub observation_count: usize,
}

impl CrossHostShape {
    pub fn host_count(&self) -> usize {
        self.hosts.len()
    }
}

/// Lists route shapes (the path-only form, stripped of host) that recur
/// across multiple hosts. Mirrors Go's Corpus.CrossHostShapes.
pub fn cross_host_shapes(cp: &Corpus, min_hosts: usize) -> Vec<CrossHostShape> {
    let min = if min_hosts == 0 { 2 } else { min_hosts };
    let mut by_shape: HashMap<String, (Vec<String>, usize)> = HashMap::new();
    for c in cp.clusters() {
        let entry = by_shape
            .entry(c.shape.clone())
            .or_insert_with(|| (Vec::new(), 0));
        if !entry.0.contains(&c.host) {
            entry.0.push(c.host.clone());
        }
        entry.1 += c.count;
    }
    let mut out: Vec<CrossHostShape> = by_shape
        .into_iter()
        .filter_map(|(shape, (mut hosts, count))| {
            if hosts.len() < min {
                None
            } else {
                hosts.sort();
                Some(CrossHostShape {
                    shape,
                    hosts,
                    observation_count: count,
                })
            }
        })
        .collect();
    out.sort_by(|a, b| {
        b.host_count()
            .cmp(&a.host_count())
            .then(b.observation_count.cmp(&a.observation_count))
            .then(a.shape.cmp(&b.shape))
    });
    out
}
