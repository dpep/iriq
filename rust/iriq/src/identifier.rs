use crate::ordered_map::OrderedMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Url,
    Urn,
}

impl Kind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Kind::Url => "url",
            Kind::Urn => "urn",
        }
    }
}

/// Parsed IRI. For URN-style inputs only Scheme + NSS are populated;
/// Host/Path are empty.
#[derive(Debug, Clone)]
pub struct Identifier {
    pub original: String,
    pub scheme: String,
    pub host: String,
    pub port: Option<u64>,
    pub path: String,
    pub path_segments: Vec<String>,
    pub query: String,
    pub query_params: OrderedMap,
    pub fragment: String,
    pub nss: String,
    pub kind: Kind,
}

impl Identifier {
    pub fn is_urn(&self) -> bool {
        self.kind == Kind::Urn
    }

    pub fn is_url(&self) -> bool {
        self.kind == Kind::Url
    }

    /// Rebuild an IRI-like string from the parsed fields. Preserves
    /// Unicode display form (no punycode / percent-encoding pass).
    pub fn canonical(&self) -> String {
        if self.is_urn() {
            return format!("{}:{}", self.scheme, self.nss);
        }
        let mut s = String::new();
        if !self.scheme.is_empty() {
            s.push_str(&self.scheme);
            s.push_str("://");
        }
        if !self.host.is_empty() {
            s.push_str(&self.host);
        }
        if let Some(port) = self.port {
            s.push(':');
            s.push_str(&port.to_string());
        }
        let has_query = !self.query.is_empty();
        let has_frag = !self.fragment.is_empty();
        if !self.path_segments.is_empty() {
            s.push('/');
            s.push_str(&self.path_segments.join("/"));
        } else if has_query || has_frag {
            s.push('/');
        }
        if has_query {
            s.push('?');
            s.push_str(&self.query);
        }
        if has_frag {
            s.push('#');
            s.push_str(&self.fragment);
        }
        s
    }

    pub fn equals(&self, other: &Identifier) -> bool {
        self.canonical() == other.canonical()
    }
}

impl std::fmt::Display for Identifier {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.canonical())
    }
}
