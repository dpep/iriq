# iriq (Go)

Go port of the [iriq](../README.md) Ruby gem: IRI extraction, normalization,
and clustering. The Ruby gem remains the reference implementation; this
package mirrors its public API and is kept in sync via golden JSON fixtures
and a CLI parity harness (see [Parity testing](#parity-testing) below).

```go
import "github.com/dpep/iriq/go/iriq"

iri, _ := iriq.Parse("https://foo.com/users/123")
iri.Scheme         // "https"
iri.Host           // "foo.com"
iri.PathSegments   // []string{"users", "123"}
iri.Canonical()    // "https://foo.com/users/123"

norm, _ := iriq.Normalize("https://foo.com/users/123")
// "https://foo.com/users/{user_id}"
```

The CLI lives at `cmd/iriq`:

```
go build -o bin/iriq ./cmd/iriq
./bin/iriq -n https://foo.com/users/123
# https://foo.com/users/{user_id}
```

## Why a Go port?

- **Startup cost.** The Ruby CLI pays ~300ms for boot + load before any work
  happens. The Go binary starts in single-digit ms.
- **Embeddable.** Other Go services can `import` this package and drop the
  CLI dependency entirely.

On a 2000-URL extraction workload (`script/bench_compare.sh`):

| Implementation | Median wall time |
| -------------- | ---------------- |
| Ruby CLI       | ~390 ms          |
| Go CLI         | ~36 ms           |

## Public API

The package surface mirrors `Iriq` in Ruby:

| Ruby                                   | Go                                           |
| -------------------------------------- | -------------------------------------------- |
| `Iriq.parse(s)`                        | `iriq.Parse(s)`                              |
| `Iriq.normalize(s)`                    | `iriq.Normalize(s)`                          |
| `Iriq.explain(s)`                      | `iriq.Explain(s)`                            |
| `Iriq.extract(text)`                   | `iriq.Extract(text)`                         |
| `Iriq::Parser.parse(s)`                | `iriq.Parse(s)`                              |
| `Iriq::Extractor.new.extract(text)`    | `iriq.NewExtractor().Extract(text)`          |
| `Iriq::Corpus.new`                     | `iriq.NewCorpus()`                           |
| `Iriq::Corpus.load(path)`              | `iriq.LoadCorpus(path)`                      |
| `Iriq::SegmentClassifier::DEFAULT`     | `iriq.DefaultClassifier`                     |
| `Iriq::Inflector.singularize(w)`       | `iriq.Singularize(w)`                        |
| `Iriq::Inflector.adapter = X`          | `iriq.SetInflectorAdapter(x)`                |
| `Iriq::PathShape.for(segs, hints: h)`  | `iriq.PathShapeFor(segs, h)`                 |

The classifier returns `SegmentType` constants (`TypeLiteral`, `TypeIntegerID`,
`TypeUUID`, `TypeDate`, `TypeTimestamp`, `TypeHash`, `TypeSlug`,
`TypeOpaqueID`) instead of Ruby symbols, and the corpus returns
`Classification` constants (`ClassStableLiteral`, etc.).

The default inflector is the rule-based built-in (the Ruby version's
`BuiltinAdapter`). Bring your own adapter with `SetInflectorAdapter`.

## Corpus JSON compatibility

`Corpus.Save` writes JSON in the same shape `Iriq::Corpus#save` does, so
files written by either implementation can be loaded by the other. Field
order inside the JSON may differ — Go's `encoding/json` sorts map keys,
Ruby preserves insertion order — but the decoded data round-trips
identically. A regression test in `iriq/fixtures_test.go::TestFixtureCorpusDump`
loads a Ruby-produced dump and asserts the aggregates match.

## Parity testing

Two layers of parity are wired into CI:

1. **Golden JSON fixtures.** `script/generate_fixtures.rb` runs the Ruby
   library over a curated set of inputs and writes
   `spec/fixtures/{parser,classifier,inflector,normalizer,pathshape,explanation,extractor,corpus_stream,corpus_dump}.json`.
   Go tests under `iriq/fixtures_test.go` load each file and assert the same
   outputs from the Go implementation. CI regenerates the fixtures and fails
   if they would change vs. what's committed.

2. **CLI parity harness.** `script/cli_parity.sh` runs the same inputs
   through both `exe/iriq` (Ruby) and the Go binary and diffs stdout. The
   parity job in CI runs this on every PR.

In addition, a focused set of RSpec examples is translated into native Go
table-driven tests for fast feedback during development (parser,
classifier, inflector, normalizer, extractor, corpus). These don't replace
the fixtures — they catch regressions without needing the Ruby toolchain.

## Layout

```
go/
  go.mod
  iriq/                 # library (importable as github.com/dpep/iriq/go/iriq)
    iriq.go             # package-level entry points (Parse, Normalize, ...)
    parser.go           # Parser
    classifier.go       # SegmentClassifier
    inflector.go        # Inflector + BuiltinInflector
    hints.go            # SegmentHints
    pathshape.go        # PathShape
    normalizer.go       # Normalizer
    explanation.go      # Explanation
    extractor.go        # Extractor
    position_stats.go   # PositionStats
    cluster.go          # Cluster
    clusterer.go        # Clusterer
    corpus.go           # Corpus
    corpus_dump.go      # save / load JSON
    observation.go      # Observation
    identifier.go       # Identifier
    ordered_map.go      # insertion-ordered string→string map
    errors.go
    version.go
    *_test.go           # native Go tests + fixture-based parity tests
  cmd/iriq/             # CLI binary (mirrors lib/iriq/cli.rb)
    main.go
    cli/cli.go
    cli/cli_test.go
```

## Development

```
# Build + test the Go package
cd go
go build ./...
go test ./...

# Regenerate fixtures (Ruby toolchain required)
cd ..
bundle install
bundle exec ruby script/generate_fixtures.rb

# Run CLI parity check
script/cli_parity.sh

# Benchmark Ruby vs Go CLI
script/bench_compare.sh
```

When you change Ruby behavior:

1. Update the Ruby code and specs.
2. Regenerate fixtures: `bundle exec ruby script/generate_fixtures.rb`.
3. Port the change to Go.
4. `go test ./...` should pass against the updated fixtures.
5. `script/cli_parity.sh` should pass.
