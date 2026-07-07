#!/usr/bin/env bash
# Side-by-side timing of JSON vs SQLite corpus backends. Same workload —
# observe 1000 URLs across 10 separate CLI invocations, then read --stats.
# The JSON backend rewrites the full dump on every save; SQLite UPSERTs
# incrementally. The gap widens as the corpus grows.
#
#   ./script/bench_storage.sh

set -euo pipefail
unset CDPATH

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST_BIN="${IRIQ_RUST_BIN:-$REPO_ROOT/rust/target/release/iriq}"

if [[ ! -x "$RUST_BIN" ]]; then
  (cd "$REPO_ROOT/rust" && cargo build --release --bin iriq 2>&1 | tail -3)
fi

# Seed input: 1000 URLs from the generator.
INPUT="$(mktemp)"
trap 'rm -f "$INPUT"' EXIT
(cd "$REPO_ROOT" && bundle exec ruby -e '
require_relative "spec/support/iri_generator"
puts IriGenerator.urls(count: 1000, seed: 42)
' > "$INPUT")

dir="$(mktemp -d)"
trap "rm -rf '$dir'; rm -f '$INPUT'" EXIT

time_one() {
  local label="$1" cmd="$2"
  local start end
  start=$(date +%s%N)
  bash -c "$cmd"
  end=$(date +%s%N)
  printf "  %-32s %4d ms\n" "$label" "$(( (end - start) / 1000000 ))"
}

echo "1000-URL batch observed in one process (cold start):"
time_one "Rust + JSON"   "$RUST_BIN --corpus '$dir/g.json' < $INPUT > /dev/null"
time_one "Rust + SQLite" "$RUST_BIN --corpus '$dir/g.db'   < $INPUT > /dev/null"

# Pre-existing large corpus: each new observation pays the load + save cost.
# JSON rewrites the whole file every time; SQLite UPSERTs are O(1) regardless
# of corpus size. Demonstrates where SQLite wins.
echo
echo "Pre-seed a 20k-observation corpus, then append 1 URL × 30 invocations:"
LARGE="$(mktemp)"
trap "rm -f '$LARGE'; rm -rf '$dir'; rm -f '$INPUT'" EXIT
(cd "$REPO_ROOT" && bundle exec ruby -e '
require_relative "spec/support/iri_generator"
puts IriGenerator.urls(count: 20000, seed: 9)
' > "$LARGE")

# Seed both backends once.
"$RUST_BIN" --corpus "$dir/big.json" < "$LARGE" > /dev/null
"$RUST_BIN" --corpus "$dir/big.db"   < "$LARGE" > /dev/null
echo "  seeded JSON: $(wc -c < $dir/big.json) bytes, SQLite: $(wc -c < $dir/big.db) bytes"

single="$(mktemp)"
echo 'https://foo.com/users/1' > "$single"

time_one "Rust + JSON   (load+save full)" "for i in \$(seq 1 30); do $RUST_BIN --corpus $dir/big.json < $single > /dev/null; done"
time_one "Rust + SQLite (incremental)"    "for i in \$(seq 1 30); do $RUST_BIN --corpus $dir/big.db   < $single > /dev/null; done"
rm -f "$single"

# Concurrent writers: 4 processes observing a quarter of the stream into the
# same corpus. JSON can't do this safely; SQLite serializes via WAL.
echo
echo "Concurrent observe (4 processes, 250 URLs each):"
split -l 250 "$INPUT" "$dir/chunk."

export RUST_BIN
export CHUNKS="$dir/chunk."

time_one "Rust + JSON (last writer wins)" "for f in $dir/chunk.*; do $RUST_BIN --corpus $dir/concurrent.json < \"\$f\" > /dev/null & done; wait"
time_one "Rust + SQLite (serialized)"      "for f in $dir/chunk.*; do $RUST_BIN --corpus $dir/concurrent.db   < \"\$f\" > /dev/null & done; wait"

json_obs=$("$RUST_BIN" --corpus "$dir/concurrent.json" --stats --json < /dev/null | grep -o '"observations":[0-9]*' | head -1)
db_obs=$("$RUST_BIN" --corpus "$dir/concurrent.db"   --stats --json < /dev/null | grep -o '"observations":[0-9]*' | head -1)
echo
echo "Observations recorded (expected: 1000):"
echo "  JSON:   $json_obs"
echo "  SQLite: $db_obs"
