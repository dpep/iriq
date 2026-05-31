package iriq

// Specificity bands for Recognizer claims. Higher wins when multiple
// Recognizers fire on the same segment; the ensemble picks
// max(specificity × confidence).
//
// Bands are coarse-grain on purpose — they encode "how surprising would
// it be for this Recognizer to fire by accident on a different actual
// type" rather than a smooth confidence axis. UUID's shape is so
// distinctive that an accidental fire is vanishingly unlikely
// (SpecificitySemantic); a 4-digit integer could plausibly be a year,
// an HTTP status, or an ID, so :integer claims only SpecificityTyped.
//
// The calibration corpus in spec/fixtures/calibration/segments.json is
// the source of truth for whether these values are well-chosen — adjust
// them and re-run TestCalibrationCorpus to validate.
const (
	// Unambiguous semantic shapes — UUID, JWT, email with @, URL with
	// ://, color hex.
	SpecificitySemantic   = 1.0
	// Restrictive structured patterns. Could collide with broader types
	// at edges. (date, file with known ext, ipv4, mime.)
	SpecificityStructured = 0.8
	// Digit-shaped with an additional bound — range or allowlist — that
	// makes the shape alone meaningful. (timestamp, currency, country,
	// boolean.)
	SpecificityBounded    = 0.7
	// Lexically broad but typed. (integer, float, version.)
	SpecificityTyped      = 0.5
	// Generic pattern-based shape. (slug.)
	SpecificityPattern    = 0.3
	// Generic fallback shapes. (literal, opaque_id.)
	SpecificityFallback   = 0.1
)
