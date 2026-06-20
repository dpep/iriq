use crate::classifier::SegmentType;
use crate::identifier::Identifier;
use crate::position::Position;

#[derive(Debug, Clone)]
pub enum Event {
    HostSeen { host: String },
    PathLengthSeen { length: usize },
    RawShapeSeen { shape: String },
    FingerprintSeen { shape: String },
    PositionSeen { position: Position, value: String, ty: SegmentType },
    ClusterAddition {
        key: String,
        host: String,
        scheme: String,
        shape: String,
        iri: Identifier,
    },
}

impl Event {
    pub fn kind(&self) -> &'static str {
        match self {
            Event::HostSeen { .. } => "host_seen",
            Event::PathLengthSeen { .. } => "path_length_seen",
            Event::RawShapeSeen { .. } => "raw_shape_seen",
            Event::FingerprintSeen { .. } => "fingerprint_seen",
            Event::PositionSeen { .. } => "position_seen",
            Event::ClusterAddition { .. } => "cluster_addition",
        }
    }
}
