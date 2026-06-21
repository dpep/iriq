use crate::classifier::{
    canonical_currency, canonical_date, display_type, SegmentClassifier, SegmentType,
    DEFAULT_CLASSIFIER,
};
use crate::hints::{derive_hints, SegmentHint};

#[derive(Debug, Clone, Default)]
pub struct Shape {
    pub entries: Vec<SegmentHint>,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct ShapeRenderOptions {
    /// Disables hint placeholders; when true, variable segments render as
    /// their display type (e.g. `{integer}`) rather than `{user_id}`.
    pub hints_off: bool,
    pub canonical_dates: bool,
    pub canonical_currencies: bool,
}

impl Shape {
    pub fn from_segments(segments: &[String], classifier: Option<&SegmentClassifier>) -> Self {
        let c = classifier.unwrap_or(&DEFAULT_CLASSIFIER);
        Shape {
            entries: derive_hints(segments, c),
        }
    }

    pub fn from_entries(entries: Vec<SegmentHint>) -> Self {
        Shape { entries }
    }

    pub fn render(&self, opts: ShapeRenderOptions) -> String {
        if self.entries.is_empty() {
            return "/".to_string();
        }
        let mut s = String::new();
        for e in &self.entries {
            s.push('/');
            s.push_str(&render_entry(e, opts));
        }
        s
    }

    pub fn equal(&self, other: &Shape) -> bool {
        self.render(ShapeRenderOptions::default()) == other.render(ShapeRenderOptions::default())
    }
}

impl std::fmt::Display for Shape {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.render(ShapeRenderOptions::default()))
    }
}

fn render_entry(e: &SegmentHint, opts: ShapeRenderOptions) -> String {
    if !e.variable {
        return e.value.clone();
    }
    if opts.canonical_dates && e.ty == SegmentType::Date {
        if let Some(c) = canonical_date(&e.value) {
            return c;
        }
    }
    if opts.canonical_currencies && e.ty == SegmentType::Currency {
        if let Some(c) = canonical_currency(&e.value) {
            return c;
        }
    }
    if !opts.hints_off && !e.hint.is_empty() {
        return format!("{{{}}}", e.hint);
    }
    format!("{{{}}}", display_type(e.ty))
}
