use crate::classifier::{SegmentClassifier, DEFAULT_CLASSIFIER};
use crate::shape::{Shape, ShapeRenderOptions};

pub struct PathShape<'a> {
    pub classifier: &'a SegmentClassifier,
    pub hints: bool,
    pub canonical_dates: bool,
    pub canonical_currencies: bool,
}

impl<'a> PathShape<'a> {
    pub fn new() -> Self {
        PathShape {
            classifier: &DEFAULT_CLASSIFIER,
            hints: true,
            canonical_dates: false,
            canonical_currencies: false,
        }
    }

    pub fn for_segments(&self, segments: &[String]) -> String {
        Shape::from_segments(segments, Some(self.classifier)).render(self.opts())
    }

    fn opts(&self) -> ShapeRenderOptions {
        ShapeRenderOptions {
            hints_off: !self.hints,
            canonical_dates: self.canonical_dates,
            canonical_currencies: self.canonical_currencies,
        }
    }
}

impl<'a> Default for PathShape<'a> {
    fn default() -> Self {
        Self::new()
    }
}

/// Convenience matching Ruby's PathShape.for.
pub fn path_shape_for(segments: &[String], hints: bool) -> String {
    let mut ps = PathShape::new();
    ps.hints = hints;
    ps.for_segments(segments)
}
