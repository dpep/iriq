use crate::errors::ParseError;
use crate::identifier::{Identifier, Kind};
use crate::ordered_map::OrderedMap;
use once_cell::sync::Lazy;
use regex::Regex;
use std::collections::HashMap;

static SCHEME_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^([a-zA-Z][a-zA-Z0-9+\-.]*):").unwrap());
// Ruby's \s and \d are ASCII-only; the regex crate's are Unicode-aware. Spell
// out the ASCII classes so Unicode whitespace stays legal in hosts and
// Unicode digits are never treated as a port, matching the Ruby reference.
static HOSTISH_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(
        r"^(?P<host>[^/?#: \t\r\n\x0B\x0C]+\.[^/?#: \t\r\n\x0B\x0C]+|localhost)(?::(?P<port>[0-9]+))?(?P<rest>[/?#].*)?$",
    )
    .unwrap()
});
static AUTH_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"^(?P<host>[^/?#]+?)(?::(?P<port>[0-9]+))?(?P<rest>[/?#].*)?$").unwrap()
});

static DEFAULT_PORTS: Lazy<HashMap<&'static str, u64>> = Lazy::new(|| {
    HashMap::from([
        ("http", 80u64),
        ("https", 443),
        ("ftp", 21),
        ("ws", 80),
        ("wss", 443),
    ])
});

/// Ruby String#strip semantics: ASCII whitespace plus NUL on both ends.
/// Rust's str::trim would also strip Unicode whitespace (e.g. U+3000),
/// which Ruby does not.
fn ruby_strip(s: &str) -> &str {
    s.trim_matches([' ', '\t', '\r', '\n', '\x0B', '\x0C', '\0'])
}

pub fn parse(input: &str) -> Result<Identifier, ParseError> {
    let stripped = ruby_strip(input);
    if stripped.is_empty() {
        return Err(ParseError::new("input is empty"));
    }

    if let Some(caps) = SCHEME_RE.captures(stripped) {
        let scheme = caps.get(1).unwrap().as_str().to_ascii_lowercase();
        let rest = &stripped[caps.get(0).unwrap().end()..];
        return match scheme.as_str() {
            "urn" => parse_urn(input, rest),
            _ if rest.starts_with("//") => parse_authority_url(input, &scheme, &rest[2..]),
            // A bare scheme with no content ("mailto:") carries no
            // identifier — and would canonicalize to "urn:", which itself
            // fails to parse — so reject it (mirrors the Ruby reference).
            _ if rest.is_empty() => Err(ParseError::new("opaque scheme missing content")),
            _ => Ok(Identifier {
                original: input.to_string(),
                scheme,
                host: String::new(),
                port: None,
                path: String::new(),
                path_segments: Vec::new(),
                query: String::new(),
                query_params: OrderedMap::new(),
                fragment: String::new(),
                nss: rest.to_string(),
                kind: Kind::Urn,
            }),
        };
    }

    if HOSTISH_RE.is_match(stripped) {
        return parse_authority_url(input, "https", stripped);
    }
    Err(ParseError::new(format!(
        "cannot parse {:?}: no scheme and no host-like prefix",
        input
    )))
}

fn parse_urn(original: &str, rest: &str) -> Result<Identifier, ParseError> {
    if rest.is_empty() {
        return Err(ParseError::new("urn missing namespace"));
    }
    Ok(Identifier {
        original: original.to_string(),
        scheme: "urn".to_string(),
        host: String::new(),
        port: None,
        path: String::new(),
        path_segments: Vec::new(),
        query: String::new(),
        query_params: OrderedMap::new(),
        fragment: String::new(),
        nss: rest.to_string(),
        kind: Kind::Urn,
    })
}

fn parse_authority_url(
    original: &str,
    scheme: &str,
    remainder: &str,
) -> Result<Identifier, ParseError> {
    let caps = HOSTISH_RE
        .captures(remainder)
        .or_else(|| AUTH_RE.captures(remainder))
        .ok_or_else(|| ParseError::new(format!("cannot parse authority from {:?}", original)))?;
    // Ruby downcases with full Unicode case mapping, not just ASCII.
    let host = caps.name("host").unwrap().as_str().to_lowercase();
    // Ruby's port.to_i is arbitrary-precision, so any digit run is accepted
    // (":0" and ":99999" included). u64 covers every realistic case;
    // KNOWN-GAP: a 20+-digit port would overflow here where Ruby accepts it.
    let mut port: Option<u64> = None;
    if let Some(p) = caps.name("port") {
        let n = p
            .as_str()
            .parse::<u64>()
            .map_err(|_| ParseError::new(format!("invalid port in {:?}", original)))?;
        port = Some(n);
    }
    if let (Some(p), Some(&default)) = (port, DEFAULT_PORTS.get(scheme)) {
        if default == p {
            port = None;
        }
    }

    let rest = caps.name("rest").map(|m| m.as_str()).unwrap_or("");
    let (path, query, fragment) = split_path_query_fragment(rest);
    let segments = path_segments(path);
    let path_built = if segments.is_empty() {
        String::new()
    } else {
        format!("/{}", segments.join("/"))
    };

    Ok(Identifier {
        original: original.to_string(),
        scheme: scheme.to_string(),
        host,
        port,
        path: path_built,
        path_segments: segments,
        query: query.to_string(),
        query_params: parse_query(query),
        fragment: fragment.to_string(),
        nss: String::new(),
        kind: Kind::Url,
    })
}

fn split_path_query_fragment(rest: &str) -> (&str, &str, &str) {
    let mut path = rest;
    let mut query = "";
    let mut fragment = "";
    if let Some(i) = path.find('#') {
        fragment = &path[i + 1..];
        path = &path[..i];
    }
    if let Some(i) = path.find('?') {
        query = &path[i + 1..];
        path = &path[..i];
    }
    (path, query, fragment)
}

fn path_segments(path: &str) -> Vec<String> {
    if path.is_empty() || path == "/" {
        return Vec::new();
    }
    let trimmed = path.strip_prefix('/').unwrap_or(path);
    let mut out = Vec::new();
    for seg in trimmed.split('/') {
        match seg {
            "" | "." => continue,
            ".." => {
                out.pop();
            }
            _ => out.push(seg.to_string()),
        }
    }
    out
}

fn parse_query(query: &str) -> OrderedMap {
    let mut out = OrderedMap::new();
    if query.is_empty() {
        return out;
    }
    for pair in query.split('&') {
        // Ruby's split("=", 2): "?flag" yields nil, "?flag=" yields "".
        let (k, v) = match pair.find('=') {
            Some(i) => (&pair[..i], Some(pair[i + 1..].to_string())),
            None => (pair, None),
        };
        if k.is_empty() {
            continue;
        }
        out.set(k, v);
    }
    out
}
