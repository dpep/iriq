use std::collections::HashMap;

/// Insertion-ordered string → string map. Mirrors Ruby Hash ordering for
/// query parameters and other fields where users see the declared order.
///
/// Values are `Option<String>` because Ruby distinguishes a valueless param
/// ("?flag" → nil) from an empty one ("?flag=" → ""). Downstream consumers
/// treat both as "" (Ruby calls `.to_s`); only the raw parse dump surfaces
/// the difference — use `iter_raw` there.
#[derive(Debug, Clone, Default)]
pub struct OrderedMap {
    keys: Vec<String>,
    values: HashMap<String, Option<String>>,
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

    pub fn set(&mut self, k: impl Into<String>, v: Option<String>) {
        let key = k.into();
        if !self.values.contains_key(&key) {
            self.keys.push(key.clone());
        }
        self.values.insert(key, v);
    }

    pub fn get(&self, k: &str) -> Option<&str> {
        self.values.get(k).and_then(|v| v.as_deref())
    }

    pub fn keys(&self) -> Vec<String> {
        self.keys.clone()
    }

    /// Values with nil collapsed to "" — Ruby's `.to_s` view.
    pub fn iter(&self) -> impl Iterator<Item = (&str, &str)> {
        self.iter_raw().map(|(k, v)| (k, v.unwrap_or("")))
    }

    /// Values as parsed: None for "?flag", Some("") for "?flag=".
    pub fn iter_raw(&self) -> impl Iterator<Item = (&str, Option<&str>)> {
        self.keys
            .iter()
            .map(move |k| (k.as_str(), self.values.get(k).and_then(|v| v.as_deref())))
    }
}
