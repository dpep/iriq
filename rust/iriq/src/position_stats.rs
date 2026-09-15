use crate::classifier::{SegmentClassifier, SegmentType};
use std::collections::HashMap;

pub const DEFAULT_MAX_VALUES_PER_POSITION: usize = 5_000;

#[derive(Debug, Clone, PartialEq)]
#[non_exhaustive]
pub struct PositionStats {
    pub value_counts: HashMap<String, usize>,
    pub type_counts: HashMap<SegmentType, usize>,
    pub total: usize,
    pub max_values: usize,
    pub numeric_count: usize,
    pub numeric_min: f64,
    pub numeric_max: f64,
    pub numeric_sum: f64,
}

impl PositionStats {
    pub fn new(max_values: usize) -> Self {
        let cap = if max_values == 0 {
            DEFAULT_MAX_VALUES_PER_POSITION
        } else {
            max_values
        };
        PositionStats {
            value_counts: HashMap::new(),
            type_counts: HashMap::new(),
            total: 0,
            max_values: cap,
            numeric_count: 0,
            numeric_min: 0.0,
            numeric_max: 0.0,
            numeric_sum: 0.0,
        }
    }

    pub fn observe(&mut self, value: &str, t: SegmentType) {
        self.total += 1;
        *self.type_counts.entry(t).or_insert(0) += 1;
        let present = self.value_counts.contains_key(value);
        if present || self.value_counts.len() < self.max_values {
            *self.value_counts.entry(value.to_string()).or_insert(0) += 1;
        }
        self.record_numeric(value, t);
    }

    fn record_numeric(&mut self, value: &str, t: SegmentType) {
        if t != SegmentType::Integer && t != SegmentType::Float {
            return;
        }
        // A 310+ digit value overflows to ±inf; it still counts as an
        // observation, but would poison min/max/avg (and JSON) as a range stat.
        let Some(n) = value.parse::<f64>().ok().filter(|n| n.is_finite()) else {
            return;
        };
        if self.numeric_count == 0 || n < self.numeric_min {
            self.numeric_min = n;
        }
        if self.numeric_count == 0 || n > self.numeric_max {
            self.numeric_max = n;
        }
        self.numeric_count += 1;
        self.numeric_sum += n;
    }

    pub fn numeric_avg(&self) -> f64 {
        if self.numeric_count == 0 {
            0.0
        } else {
            self.numeric_sum / (self.numeric_count as f64)
        }
    }

    pub fn cardinality(&self) -> usize {
        self.value_counts.len()
    }

    pub fn variable_fraction(&self, c: &SegmentClassifier) -> f64 {
        if self.total == 0 {
            return 0.0;
        }
        let v: usize = self
            .type_counts
            .iter()
            .filter(|(t, _)| c.variable(**t))
            .map(|(_, n)| *n)
            .sum();
        (v as f64) / (self.total as f64)
    }

    pub fn value_fraction(&self, value: &str) -> f64 {
        if self.total == 0 {
            return 0.0;
        }
        let n = *self.value_counts.get(value).unwrap_or(&0);
        (n as f64) / (self.total as f64)
    }

    /// SegmentType with the largest count. Ties broken lexicographically
    /// (by the type's display string) for cross-runtime determinism.
    pub fn dominant_type(&self) -> SegmentType {
        let mut best: Option<(SegmentType, usize)> = None;
        for (&t, &n) in &self.type_counts {
            best = match best {
                None => Some((t, n)),
                Some((bt, bn)) => {
                    if n > bn || (n == bn && t.as_str() < bt.as_str()) {
                        Some((t, n))
                    } else {
                        Some((bt, bn))
                    }
                }
            };
        }
        best.map(|(t, _)| t).unwrap_or(SegmentType::Literal)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn non_finite_numbers_count_as_observations_but_not_as_range_stats() {
        // 400 digits overflows f64 to ±inf.
        let huge = "1".repeat(400);
        let mut stats = PositionStats::new(0);
        stats.observe(&huge, SegmentType::Integer);
        assert_eq!(
            stats.numeric_count, 0,
            "an all-infinite position has no range"
        );

        stats.observe("1", SegmentType::Integer);
        stats.observe(&format!("-{huge}.5"), SegmentType::Float);
        stats.observe("3.5", SegmentType::Float);
        assert_eq!(stats.total, 4);
        assert_eq!(stats.type_counts[&SegmentType::Integer], 2);
        assert_eq!(stats.cardinality(), 4);
        assert_eq!(
            (stats.numeric_count, stats.numeric_min, stats.numeric_max),
            (2, 1.0, 3.5)
        );
        assert_eq!(stats.numeric_avg(), 2.25);
    }
}
