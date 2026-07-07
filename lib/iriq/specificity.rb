module Iriq
  # Per-Recognizer claim strength. Higher specificity wins when multiple
  # Recognizers fire on the same segment; the ensemble picks the
  # max(specificity × confidence).
  #
  # The bands below capture the current type taxonomy at coarse-grain:
  # they're explicitly NOT linear "how confident" scores. They encode "how
  # surprising would it be for this Recognizer to fire by accident on a
  # different actual type." UUID's shape is so distinctive that a non-UUID
  # producing that string is vanishingly unlikely (SEMANTIC); a 4-digit
  # integer could plausibly be a year, an HTTP status, or an ID, so
  # `:integer` claims only TYPED.
  #
  # Calibration corpus tests in spec/iriq/calibration_spec.rb are the
  # source of truth for whether these values are well-chosen — adjust
  # them and re-run to validate.
  module Specificity
    # Unambiguous semantic shapes — the regex effectively can't fire by
    # accident. (UUID, JWT, email with @, URL with ://, color hex.)
    SEMANTIC   = 1.0
    # Restrictive structured patterns. Could collide with broader types
    # at edges. (date, file with known ext, ipv4, mime.)
    STRUCTURED = 0.8
    # Digit-shaped with an additional bound — range or allowlist — that
    # makes the shape alone meaningful. (timestamp, currency, country,
    # boolean.)
    BOUNDED    = 0.7
    # Lexically broad but typed. (integer, float, version.)
    TYPED      = 0.5
    # Generic pattern-based shape. (slug.)
    PATTERN    = 0.3
    # Generic fallback shapes. (literal, opaque_id.)
    FALLBACK   = 0.1
  end
end
