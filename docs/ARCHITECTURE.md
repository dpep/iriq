# iriq architecture

As of v0.28.0, this describes the system that's actually in the repo —
Phase 1 of the rearchitecture roadmap (target model below) is complete,
and Phase 2 has added the learning layer on top. Originally written as
the *target* model at the start of Phase 1; the implementation has
caught up.

`ROADMAP.md` tracks what's still pending (inter-position correlations,
near-shape clustering, and Phase 3 productize items).

For the inner details, read the source: `lib/iriq/{recognizer,position,
shape,evidence,event,reducer,recognizer_proposal,synthesized_recognizer,
cross_host_shape,corpus}.rb` and their Go counterparts at the repo root.

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

## Extensibility (where it stands)

- **Recognizer registry**: per-classifier and mutable as of v0.26.
  `SegmentClassifier#register_recognizer` appends to the instance's
  ensemble; `SegmentClassifier::DEFAULT` is the module-level singleton
  that fresh corpora share, and the first `Corpus#activate_proposal`
  call swaps to a private classifier so activations don't leak.
  External users registering their own Recognizer subclasses works
  today via the same API; an *external* registry / discovery surface
  (load Recognizers from a config file or env var) is still future
  work.
- **ProposalStrategy**: pluggable via `Iriq::ProposalStrategy::DEFAULTS`.
  Adding a strategy = define a class with `#propose(storage, **opts)`
  and append. v1 ships one strategy (PrefixUnderscoreId); next-segment
  / cross-position correlation strategies are pending Phase 2 work.
- **Reducer registry**: the dispatch table `Iriq::Reducer::DEFAULTS`
  maps `Event` subclasses to reducer lambdas. Adding a metric = define
  an `Event` subtype, write a Reducer, register it. The registry is
  exposed as a constant; safe to monkeypatch in user code, though no
  public registration API ships yet.
- **Storage backends**: three ship (Memory, JSON, SQLite). Adding a
  fourth = implement the `Storage` interface (lib/iriq/storage/memory.rb
  is the canonical reference), wire it into `Storage.open` extension
  routing, add it to `script/cli_parity.sh`.

## Learning layer (Phase 2, on top of the substrate above)

The Phase 1 substrate gives us typed observations, structured Shape,
and re-runnable inference. Phase 2 builds the learning pipeline on top:

- **Source-IRI log** (v0.21). Storage persists every observed canonical
  IRI alongside the materialized views. `Corpus#reinfer` drops the
  views and replays the log through the current classifier + reducers
  — lets us tune thresholds or swap the classifier without re-feeding.
- **RecognizerProposal** (v0.23). A struct describing a learned
  pattern: prefix / suggested_type / positions / hosts / coverage /
  confidence / observation_count / sample_values / strategy.
  Emitted by ProposalStrategy implementations; not auto-applied.
- **SynthesizedRecognizer** (v0.26). Built from a proposal's prefix;
  regex `^<prefix>[A-Za-z0-9]+$`, `Specificity::SEMANTIC`. Same
  Recognizer interface as the built-ins (UUID, Date, Integer) — the
  ensemble doesn't know the difference.
- **CrossHostShape** (v0.27). Read-side: route shapes that recur
  across multiple hosts. Independent evidence of semantic pattern.
- **Confidence formula** (v0.28). `min(1.0, coverage + 0.05 *
  (host_count - 1))`. Single-host proposals are unchanged; cross-host
  proposals get boosted. `--activate-above F` checks confidence.
