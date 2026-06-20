// Position is a typed slot in a host's URL structure. Two observations
// occupy the same Position when (host, scope, locator) match.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PositionScope {
    Path,
    Query,
}

impl PositionScope {
    pub fn as_str(&self) -> &'static str {
        match self {
            PositionScope::Path => "path",
            PositionScope::Query => "query",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Position {
    pub host: String,
    pub scope: PositionScope,
    pub locator: String,
}

impl Position {
    pub fn path(host: impl Into<String>, prefix: impl Into<String>) -> Self {
        Position { host: host.into(), scope: PositionScope::Path, locator: prefix.into() }
    }
    pub fn query(host: impl Into<String>, name: impl Into<String>) -> Self {
        Position { host: host.into(), scope: PositionScope::Query, locator: name.into() }
    }
}
