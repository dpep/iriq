#!/usr/bin/env bash
# Side-by-side timing of the Ruby CLI and the Go CLI on a representative
# extraction workload. Not a microbenchmark — measures real CLI start +
# parse + extract + observe wall time, which is what users actually feel.
#
#   ./script/bench_compare.sh [iterations]
#
# Iterations default to 5. The script feeds the same generated input through
# both implementations and reports the median wall-clock time.

set -euo pipefail
unset CDPATH  # don't let user CDPATH leak into our path resolution

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ITERS="${1:-5}"
GO_BIN="${IRIQ_GO_BIN:-$REPO_ROOT/bin/iriq}"

export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

if [[ ! -x "$GO_BIN" ]]; then
  echo "Building Go binary..." >&2
  mkdir -p "$(dirname "$GO_BIN")"
  (cd "$REPO_ROOT" && go build -o "$GO_BIN" ./cmd/iriq)
fi

# Generate a fixed input file: 2000 synthetic URLs from the spec generator.
INPUT="$(mktemp)"
trap 'rm -f "$INPUT"' EXIT
(cd "$REPO_ROOT" && bundle exec ruby -e '
require_relative "spec/support/iri_generator"
puts IriGenerator.urls(count: 2000, seed: 42)
' > "$INPUT")

bytes=$(wc -c < "$INPUT")
echo "Input: $(wc -l < "$INPUT") URLs, ${bytes} bytes"
echo "Running each implementation $ITERS times with -n..."

time_one() {
  local label="$1"
  local cmd="$2"
  local times=()
  for ((i=0; i<ITERS; i++)); do
    local start end
    start=$(date +%s%N)
    bash -c "$cmd" < "$INPUT" > /dev/null
    end=$(date +%s%N)
    times+=( $(( (end - start) / 1000000 )) )
  done
  IFS=$'\n' sorted=($(printf '%d\n' "${times[@]}" | sort -n))
  unset IFS
  local median="${sorted[$((ITERS / 2))]}"
  printf "  %-8s median=%4dms  all=%s\n" "$label" "$median" "${times[*]}"
}

time_one "ruby" "bundle exec --gemfile=$REPO_ROOT/Gemfile $REPO_ROOT/exe/iriq -n"
time_one "go"   "$GO_BIN -n"
