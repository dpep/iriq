use std::path::{Path, PathBuf};
use thiserror::Error;

/// Input that isn't a parseable IRI. The only way the pure functions
/// ([`parse`](crate::parse), [`normalize`](crate::normalize),
/// [`trace`](crate::trace), [`explain`](crate::explain)) can fail.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[error("parse error: {0}")]
pub struct ParseError(String);

impl ParseError {
    pub(crate) fn new(msg: impl Into<String>) -> Self {
        ParseError(msg.into())
    }

    /// What was wrong with the input, without the `parse error:` prefix.
    pub fn message(&self) -> &str {
        &self.0
    }
}

/// Everything a [`Corpus`](crate::Corpus) operation can fail with.
///
/// `Display` names what failed; the underlying cause, when there is one, is
/// [`source()`](std::error::Error::source).
#[derive(Debug, Error)]
#[non_exhaustive]
pub enum Error {
    /// An input string isn't a parseable IRI.
    #[error(transparent)]
    Parse(#[from] ParseError),

    /// Reading or writing the corpus file failed.
    #[error("corpus {}", path.display())]
    #[non_exhaustive]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    /// The file exists but isn't a usable iriq corpus.
    #[error("corpus {}: {reason}", path.display())]
    #[non_exhaustive]
    Corrupt { path: PathBuf, reason: String },

    /// The corpus is valid but this build of iriq can't use it.
    #[error("corpus {}: {reason}", path.display())]
    #[non_exhaustive]
    Unsupported { path: PathBuf, reason: String },

    /// SQLite rejected an operation on the corpus. The source is the
    /// `rusqlite::Error`, boxed so the public API doesn't pin a rusqlite
    /// version.
    #[cfg(feature = "sqlite")]
    #[cfg_attr(docsrs, doc(cfg(feature = "sqlite")))]
    #[error("corpus {}", path.display())]
    #[non_exhaustive]
    Sqlite {
        path: PathBuf,
        #[source]
        source: Box<dyn std::error::Error + Send + Sync>,
    },
}

/// `Result` with [`Error`](enum@Error) as the default error type.
pub type Result<T, E = Error> = std::result::Result<T, E>;

impl Error {
    pub(crate) fn io(path: &Path, source: std::io::Error) -> Self {
        Error::Io {
            path: path.to_path_buf(),
            source,
        }
    }

    pub(crate) fn corrupt(path: &Path, reason: impl Into<String>) -> Self {
        Error::Corrupt {
            path: path.to_path_buf(),
            reason: reason.into(),
        }
    }

    pub(crate) fn unsupported(path: &Path, reason: impl Into<String>) -> Self {
        Error::Unsupported {
            path: path.to_path_buf(),
            reason: reason.into(),
        }
    }

    #[cfg(feature = "sqlite")]
    pub(crate) fn sqlite(path: &Path, source: rusqlite::Error) -> Self {
        Error::Sqlite {
            path: path.to_path_buf(),
            source: Box::new(source),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_a_well_behaved_error() {
        fn assert_error<T: std::error::Error + Send + Sync + 'static>() {}
        assert_error::<Error>();
        assert_error::<ParseError>();
    }

    #[test]
    fn display_names_the_path_and_source_carries_the_cause() {
        let e = Error::io(
            Path::new("/x/c.json"),
            std::io::Error::from(std::io::ErrorKind::NotFound),
        );
        assert_eq!(e.to_string(), "corpus /x/c.json");
        assert!(std::error::Error::source(&e).is_some());
    }
}
