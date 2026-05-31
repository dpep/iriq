# iriq architecture (target model)

This is the **end-state** model we are migrating toward in Phase 1. Current
code does not match this yet — `ROADMAP.md` tracks the migration.

For the description of what's in the repo *today*, read the source
(particularly `lib/iriq/segment_classifier.rb`, `lib/iriq/corpus.rb`, and
`lib/iriq/cluster.rb`).

## Core principle

The system pivots around **Position** (a slot in a host's structure) and
**Evidence** (what we know about a Position). Strings are observations;
types are inferences. Everything composable hangs off these two nouns.

## Core types

### Identifier (existing, mostly unchanged)

A parsed IRI: scheme, host, port, path_segments, query_params, fragment,
plus `kind ∈ {:url, :urn}` and the urn `nss`. Produced by `Parser` from a
candidate string; produced in bulk by `Extractor` from free text.

### Position (new)

A stable identity for a slot in a host's structure.

```
Position {
  host:    string        # normalized per host_strategy (full|registrable|none)
  scope:   :path | :query
  locator: path_prefix   # for :path — the typed-shape prefix that led here
         | param_name    # for :query — the ?key= name
}
```

Two Identifiers occupy the *same* Position when their hosts agree and their
typed prefix agrees. "Typed prefix" means the prefix rendered with inferred
types (`/users/{integer}/...`), not raw values. This makes Position identity
robust to the specific values seen.

### Recognizer (new)

A pluggable classifier for a single (or small family of) types.

```
Recognizer#try(string) -> { type:, confidence:, canonical:, notes: } | nil
```

- `type` is a symbol from the recognized vocabulary (uuid, date, integer, …).
- `confidence` is in `[0, 1]`. Calibrated against
  `spec/fixtures/calibration/`.
- `canonical` is the canonical form (e.g. ISO date for `:date`, uppercased
  ISO 4217 for `:currency`). `nil` means "use the input as-is".
- `notes` is an optional array of strings the Trace view may surface.

Recognizers are independent. There is no global ordering. The
**SegmentClassifier becomes an ensemble** that runs each Recognizer and
picks the highest-confidence answer above a floor. `:literal` is the
fallback when no Recognizer fires above the floor.

### Evidence (new)

The universal substrate for explanation. A small fixed schema, emitted by
both classification and inference.

```
Evidence {
  position: Position
  kind:     :lexical | :corpus | :recognizer | :neighbor | :policy
  payload:  { ... kind-specific fields ... }
  weight:   float in [0, 1]      # contribution to the final inference
}
```

Examples:
- `:recognizer` payload: `{ name:, type:, lexical_confidence: }`
- `:corpus` payload: `{ observations:, distinct_values:, cardinality_frac: }`
- `:neighbor` payload: `{ prior_literal:, inferred_hint: }`
- `:policy` payload: `{ rule:, applied: }` (e.g. "ipv4→ip umbrella collapse")

`Trace` and `Explanation` are *views* over a list of Evidence. They render
strings for human consumption but the data shape is shared.

### Shape (new — replaces PathShape strings as the identity)

An ordered list of typed Positions for a single Identifier path:

```
Shape { positions: [Position], inferred_types: [Symbol] }
```

`Shape#render(:string)` produces the human-readable form (`/users/{user_id}`)
that today's `PathShape` produces. Cluster identity is the structural Shape,
not the string. String renderings are derived for display, not for keying.

### Cluster (existing; refactored)

Same role: a group of Identifiers sharing (host, Shape). Internals shift to
key on structural Shape; aggregation (`PositionStats`) is unchanged.
Inference (variability promotion, enum detection, etc.) moves *out* of
Cluster and into its own stage so it can be re-run over stored evidence
without re-feeding observations.

### Reducer (new)

A function over the event stream that maintains a materialized view.

```
Reducer#apply(event, state) -> state
```

Examples ship in v1:
- `HostCountsReducer`
- `PositionStatsReducer`
- `ClusterReducer`
- `FingerprintReducer`

Storage backends store the event log (or, equivalently, the materialized
views — backends choose). Adding a new metric is: write a Reducer, declare
its state shape; no other module changes.

## Pipeline (target end-state)

```
text
 └─► Extractor       ─► [candidate strings]
       └─► Parser    ─► Identifier
             └─► Recognition  ─► annotated segments + per-segment Evidence
                   └─► Events ─► Storage event log
                                  └─► Reducers ─► materialized views
                                                   (PositionStats, Clusters, ...)
                                        ├─► Inference  ─► per-Position type + Evidence
                                        └─► Rendering  ─► normalized string / Shape view
```

Each stage is a separate module with input/output contracts. Inference
re-reads materialized views; it does not require re-running the pipeline.

## What this fixes (vs. the today code)

- **No more string-fingerprint cluster keys.** Classifier tuning no longer
  fractures clusters.
- **No more order-dependent first-match classifier.** Add a Recognizer
  without considering global ordering.
- **`SegmentClassifier` stops being a god module.** Recognizers own their
  patterns and canonical forms; reference data (locales, currencies,
  countries) lives in `ReferenceData::*`; display names / variability
  predicate live in a small `Policy` / `Naming` module.
- **One Normalizer.** Mechanical mode is "NullEvidence" — no special case.
- **Two-axis type taxonomy.** Lexical shape and semantic role can grow
  independently. Cardinality character is a *property of Position*, not of
  type — `:year`, `:http_status`, `:enum` collapse into "integer-shape +
  bounded-cardinality" expressed via Evidence.
- **Re-runnable inference.** Threshold tuning no longer requires
  re-observation.
- **One explanation substrate.** Trace, Explanation, future schema export,
  future PR-diff annotator are all views over Evidence.

## What stays the same

- `Identifier` as the parsed record.
- `Parser` + `Extractor` — already cleanly separated.
- `Storage::*` backends (Memory, Json, Sqlite). Internals change to persist
  events rather than ad-hoc counters, but the file-extension routing API
  (`Corpus.open(path)`) stays.
- Public CLI surface (`exe/iriq`, the Go `cmd/iriq` binary).
- The four `Iriq.*` module methods: `parse`, `normalize`, `explain`,
  `extract`.

## Extensibility (internal-only in v1)

The Recognizer registry is internal-only for v1 — `SegmentClassifier::DEFAULT`
is loaded from a built-in list. The seam exists so an external `register!`
call drops in as a small follow-up. Designing the v1 internals to support
this is the explicit goal even though we don't ship the public API yet.

Same for Reducers: built-in set is fixed in v1; adding the registry surface
is a Phase 3 deliverable.
