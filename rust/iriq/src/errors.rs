use thiserror::Error;

#[derive(Debug, Clone, Error)]
#[error("iriq: parse error: {0}")]
pub struct ParseError(pub String);

impl ParseError {
    pub fn new(msg: impl Into<String>) -> Self {
        ParseError(msg.into())
    }
}
