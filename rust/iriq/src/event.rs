use crate::classifier::SegmentType;
use crate::identifier::Identifier;
use crate::position::Position;

#[derive(Debug, Clone)]
pub enum Event {
    HostSeen {
        host: String,
    },
    PathLengthSeen {
        length: usize,
    },
    RawShapeSeen {
        shape: String,
    },
    FingerprintSeen {
        shape: String,
    },
    PositionSeen {
        position: Position,
        value: String,
        ty: SegmentType,
    },
    ClusterAddition {
        key: String,
        host: String,
        scheme: String,
        shape: String,
        iri: Box<Identifier>,
    },
}
