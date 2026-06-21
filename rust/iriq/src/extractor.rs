use crate::identifier::Identifier;
use crate::parser::parse;
use once_cell::sync::Lazy;
use regex::Regex;
use std::collections::HashSet;

pub struct Extractor {
    pub scheme_less: bool,
}

impl Extractor {
    pub fn new() -> Self {
        Extractor { scheme_less: true }
    }

    pub fn extract(&self, text: &str) -> Vec<Identifier> {
        if text.is_empty() {
            return Vec::new();
        }
        let pattern: &Regex = if self.scheme_less {
            &COMBINED_RE
        } else {
            &CANDIDATE_RE
        };
        let mut out = Vec::new();
        for m in pattern.find_iter(text) {
            if !left_boundary_ok(text, m.start(), self.scheme_less) {
                continue;
            }
            let candidate = m.as_str();
            let trimmed = trim_candidate(candidate);
            if trimmed.is_empty() {
                continue;
            }
            if let Ok(iri) = parse(&trimmed) {
                out.push(iri);
            }
        }
        out
    }

    pub fn extract_strings(&self, text: &str) -> Vec<String> {
        let mut seen = HashSet::new();
        let mut out = Vec::new();
        for iri in self.extract(text) {
            let c = iri.canonical();
            if seen.insert(c.clone()) {
                out.push(c);
            }
        }
        out
    }
}

impl Default for Extractor {
    fn default() -> Self {
        Self::new()
    }
}

const SCHEMES: &[&str] = &["https", "http", "ftp", "wss", "ws"];
const SCHEMELESS_TLDS: &[&str] = &[
    "com", "org", "net", "io", "ai", "dev", "co", "app", "gov", "edu",
];

const NON_ASCII_BOUNDARY: &str =
    "」』）】〉》〕〗〙〛｠｝］＞「『（【〈《〔〖〘〚｟｛［＜“”‘’„‟‚«»‹›";

fn url_chars_class() -> String {
    let mut escaped = String::new();
    let mut seen: HashSet<char> = HashSet::new();
    for c in NON_ASCII_BOUNDARY.chars() {
        if !seen.insert(c) {
            continue;
        }
        if matches!(c, ']' | '\\' | '^' | '-') {
            escaped.push('\\');
        }
        escaped.push(c);
    }
    format!(r#"[^\s<>"'`,{}]+"#, escaped)
}

static CANDIDATE_RE: Lazy<Regex> = Lazy::new(|| {
    let url_chars = url_chars_class();
    let pat = format!(
        r"(?:(?i:{schemes})://{u}|urn:[a-zA-Z0-9][a-zA-Z0-9\-]{{0,30}}:{u})",
        schemes = SCHEMES.join("|"),
        u = url_chars,
    );
    Regex::new(&pat).unwrap()
});

static COMBINED_RE: Lazy<Regex> = Lazy::new(|| {
    let url_chars = url_chars_class();
    let pat = format!(
        r"(?:(?i:{schemes})://{u}|urn:[a-zA-Z0-9][a-zA-Z0-9\-]{{0,30}}:{u}|(?:[a-zA-Z0-9](?:[a-zA-Z0-9\-]{{0,61}}[a-zA-Z0-9])?\.)+(?i:{tlds})/{u})",
        schemes = SCHEMES.join("|"),
        tlds = SCHEMELESS_TLDS.join("|"),
        u = url_chars,
    );
    Regex::new(&pat).unwrap()
});

static TRAILING_PUNCT_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"[.,;:!?'"\u{2018}\u{2019}\u{201C}\u{201D}]+$"#).unwrap());

fn bracket_pair(c: char) -> Option<char> {
    match c {
        ')' => Some('('),
        ']' => Some('['),
        '}' => Some('{'),
        _ => None,
    }
}

fn left_boundary_ok(text: &str, start: usize, schemeless: bool) -> bool {
    if start == 0 {
        return true;
    }
    let prev = text[..start].chars().last();
    let Some(r) = prev else {
        return true;
    };
    if is_word(r) {
        return false;
    }
    if r == '/' {
        return false;
    }
    if schemeless && (r == '.' || r == '@') {
        return false;
    }
    true
}

fn is_word(c: char) -> bool {
    c == '_' || c.is_alphabetic() || c.is_numeric() || matches!(c, '\u{0300}'..='\u{036F}')
}

fn trim_candidate(candidate: &str) -> String {
    let mut s = candidate.to_string();
    loop {
        let before = s.clone();
        s = TRAILING_PUNCT_RE.replace(&s, "").into_owned();
        for close in [')', ']', '}'] {
            let open = bracket_pair(close).unwrap();
            while !s.is_empty() && s.ends_with(close) {
                let close_count = s.chars().filter(|&c| c == close).count();
                let open_count = s.chars().filter(|&c| c == open).count();
                if close_count > open_count {
                    let mut chars = s.chars();
                    chars.next_back();
                    s = chars.as_str().to_string();
                } else {
                    break;
                }
            }
        }
        if s == before {
            return s;
        }
    }
}
