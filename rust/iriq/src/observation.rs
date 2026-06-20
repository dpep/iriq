use crate::identifier::Identifier;

#[derive(Debug, Clone)]
pub struct Observation {
    pub iri: Identifier,
    pub cluster_key: String,
}
