// Built-in English singularizer. Rules adapted from ActiveSupport defaults
// via the Go port. Mirrors the same precedence and irregular/uncountable
// lists so output is bit-identical across runtimes.

use once_cell::sync::Lazy;
use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

const CACHE_MAX: usize = 10_000;

static IRREGULARS: Lazy<HashMap<&'static str, &'static str>> = Lazy::new(|| {
    let mut m = HashMap::new();
    m.insert("people", "person");
    m.insert("children", "child");
    m.insert("men", "man");
    m.insert("women", "woman");
    m.insert("mice", "mouse");
    m.insert("geese", "goose");
    m.insert("oxen", "ox");
    m.insert("feet", "foot");
    m.insert("teeth", "tooth");
    m.insert("lives", "life");
    m.insert("wives", "wife");
    m.insert("moves", "move");
    m.insert("zombies", "zombie");
    m.insert("indices", "index");
    m.insert("vertices", "vertex");
    m.insert("leaves", "leaf");
    m.insert("calves", "calf");
    m.insert("halves", "half");
    m.insert("loaves", "loaf");
    m.insert("hooves", "hoof");
    m
});

static UNCOUNTABLE: Lazy<HashSet<&'static str>> = Lazy::new(|| {
    [
        "news", "fish", "sheep", "deer", "series", "species",
        "equipment", "information", "money", "rice", "jeans",
        "police", "data", "media",
    ]
    .iter()
    .copied()
    .collect()
});

struct Rule {
    re: Regex,
    repl: &'static str,
}

static RULES: Lazy<Vec<Rule>> = Lazy::new(|| {
    vec![
        Rule { re: Regex::new(r"(?i)(quiz)zes$").unwrap(), repl: "${1}" },
        Rule { re: Regex::new(r"(?i)(matri|appendi)ces$").unwrap(), repl: "${1}x" },
        Rule { re: Regex::new(r"(?i)(ox)en$").unwrap(), repl: "${1}" },
        Rule { re: Regex::new(r"(?i)(alias|status)(es)?$").unwrap(), repl: "${1}" },
        Rule { re: Regex::new(r"(?i)(octop|vir)(us|i)$").unwrap(), repl: "${1}us" },
        Rule { re: Regex::new(r"(?i)(cris|ax|test)es$").unwrap(), repl: "${1}is" },
        Rule { re: Regex::new(r"(?i)(shoe)s$").unwrap(), repl: "${1}" },
        Rule { re: Regex::new(r"(?i)(bus)(es)?$").unwrap(), repl: "${1}" },
        Rule { re: Regex::new(r"(?i)([ml])ice$").unwrap(), repl: "${1}ouse" },
        Rule { re: Regex::new(r"(?i)(x|ch|ss|sh)es$").unwrap(), repl: "${1}" },
        Rule { re: Regex::new(r"(?i)(m)ovies$").unwrap(), repl: "${1}ovie" },
        Rule { re: Regex::new(r"(?i)(s)eries$").unwrap(), repl: "${1}eries" },
        Rule { re: Regex::new(r"(?i)([^aeiouy]|qu)ies$").unwrap(), repl: "${1}y" },
        Rule { re: Regex::new(r"(?i)([lr])ves$").unwrap(), repl: "${1}f" },
        Rule { re: Regex::new(r"(?i)(tive)s$").unwrap(), repl: "${1}" },
        Rule { re: Regex::new(r"(?i)(hive)s$").unwrap(), repl: "${1}" },
        Rule { re: Regex::new(r"(?i)([^f])ves$").unwrap(), repl: "${1}fe" },
        Rule {
            re: Regex::new(
                r"(?i)((a)naly|(b)a|(d)iagno|(p)arenthe|(p)rogno|(s)ynop|(t)he)ses$",
            )
            .unwrap(),
            repl: "${1}sis",
        },
        Rule { re: Regex::new(r"(?i)([ti])a$").unwrap(), repl: "${1}um" },
        Rule { re: Regex::new(r"(?i)(n)ews$").unwrap(), repl: "${1}ews" },
        Rule { re: Regex::new(r"(?i)(o)es$").unwrap(), repl: "${1}" },
        Rule { re: Regex::new(r"(?i)(ss)$").unwrap(), repl: "${1}" },
        Rule { re: Regex::new(r"(?i)s$").unwrap(), repl: "" },
    ]
});

static CACHE: Lazy<Mutex<HashMap<String, String>>> = Lazy::new(|| Mutex::new(HashMap::new()));

pub fn singularize(word: &str) -> String {
    {
        let mut cache = CACHE.lock().unwrap();
        if let Some(v) = cache.get(word) {
            return v.clone();
        }
        if cache.len() >= CACHE_MAX {
            cache.clear();
        }
    }
    let out = singularize_inner(word);
    let mut cache = CACHE.lock().unwrap();
    cache.insert(word.to_string(), out.clone());
    out
}

fn singularize_inner(word: &str) -> String {
    if word.is_empty() {
        return word.to_string();
    }
    let lower = word.to_lowercase();
    if UNCOUNTABLE.contains(lower.as_str()) {
        return word.to_string();
    }
    if let Some(&irr) = IRREGULARS.get(lower.as_str()) {
        return preserve_case(word, irr);
    }
    for r in RULES.iter() {
        if r.re.is_match(word) {
            return r.re.replace(word, r.repl).into_owned();
        }
    }
    word.to_string()
}

fn preserve_case(original: &str, lowered: &str) -> String {
    if original == original.to_uppercase() {
        return lowered.to_uppercase();
    }
    if let Some(first) = original.chars().next() {
        if first.is_uppercase() {
            let mut chars = lowered.chars();
            if let Some(c) = chars.next() {
                let upper: String = c.to_uppercase().collect();
                let rest: String = chars.collect();
                return upper + &rest;
            }
        }
    }
    lowered.to_string()
}
