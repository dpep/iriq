module Iriq
  # Pluggable single-type classifier.
  #
  # A Recognizer encapsulates "this string-shape implies this type" plus the
  # canonical form (if any). The ensemble-based SegmentClassifier consults
  # Recognizers in order and picks the first that fires. (Scored-ensemble
  # voting comes in a follow-up; for now each fire is decisive.)
  #
  # try(segment) -> { type:, confidence:, canonical:, notes: } | nil
  #   nil   — this Recognizer does not claim the segment.
  #   type  — symbol from the recognized vocabulary.
  #   confidence — float in [0, 1]. Phase-1 step 2 always returns 1.0
  #     when a Recognizer fires; calibration arrives with the scored
  #     ensemble in step 4.
  #   canonical — canonical form (e.g. ISO date for :date). nil ≡ "use input".
  #   notes — optional array of strings the Trace view may surface.
  #
  # Recognizers are instantiated once and shared (they hold no per-call
  # state). See Iriq::Recognizers::UUID / DATE / INTEGER for the built-ins.
  class Recognizer
    def try(_segment)
      raise NotImplementedError
    end

    # Run each Recognizer against the segment and return the winning
    # Verdict — the one with max(specificity × confidence). Ties go to
    # the earlier Recognizer in the list (stable, deterministic).
    # Returns nil when no Recognizer fires.
    #
    # Stepping-stone toward the full scored ensemble: today only three
    # Recognizers participate (uuid, date, integer) and they're
    # mutually-exclusive on shape, so the ensemble is effectively a
    # short-circuit OR. As more Recognizers carve out of SegmentClassifier
    # they'll join the pool and the scoring becomes load-bearing.
    def self.ensemble(segment, recognizers)
      best = nil
      best_score = -1.0
      recognizers.each do |r|
        v = r.try(segment)
        next unless v

        score = (v[:specificity] || 0.0) * (v[:confidence] || 0.0)
        if score > best_score
          best       = v
          best_score = score
        end
      end
      best
    end
  end

  module Recognizers
  end
end
