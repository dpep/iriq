use std::collections::HashMap;

/// Insertion-ordered string → string map. Mirrors Go's OrderedMap which in
/// turn mirrors Ruby Hash ordering for query parameters and other fields
/// where users see the declared order.
#[derive(Debug, Clone, Default)]
pub struct OrderedMap {
    keys: Vec<String>,
    values: HashMap<String, String>,
}

impl OrderedMap {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.keys.len()
    }

    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }

    pub fn set(&mut self, k: impl Into<String>, v: impl Into<String>) {
        let key = k.into();
        if !self.values.contains_key(&key) {
            self.keys.push(key.clone());
        }
        self.values.insert(key, v.into());
    }

    pub fn get(&self, k: &str) -> Option<&str> {
        self.values.get(k).map(String::as_str)
    }

    pub fn keys(&self) -> Vec<String> {
        self.keys.clone()
    }

    pub fn iter(&self) -> impl Iterator<Item = (&str, &str)> {
        self.keys
            .iter()
            .map(move |k| (k.as_str(), self.values.get(k).map(String::as_str).unwrap_or("")))
    }
}
