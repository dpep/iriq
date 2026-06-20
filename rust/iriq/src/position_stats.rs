use crate::classifier::{SegmentClassifier, SegmentType};
use std::collections::HashMap;

pub const DEFAULT_MAX_VALUES_PER_POSITION: usize = 5_000;

#[derive(Debug, Clone)]
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
        let cap = if max_values == 0 { DEFAULT_MAX_VALUES_PER_POSITION } else { max_values };
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
        let Ok(n) = value.parse::<f64>() else { return; };
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
