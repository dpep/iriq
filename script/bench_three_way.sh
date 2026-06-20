#!/usr/bin/env bash
# Three-way wall-clock comparison: Go vs Rust on a fixed extraction
# workload. Doesn't run Ruby — that requires Ruby 3.4+ which isn't always
# available in the spike environment. Run script/bench_compare.sh
# separately to get the Ruby column.

set -euo pipefail
unset CDPATH

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ITERS="${1:-5}"
GO_BIN="${IRIQ_GO_BIN:-$REPO_ROOT/bin/iriq}"
RUST_BIN="${IRIQ_RUST_BIN:-$REPO_ROOT/rust/target/release/iriq}"

if [[ ! -x "$GO_BIN" ]]; then
  (cd "$REPO_ROOT" && go build -o "$GO_BIN" ./cmd/iriq)
fi
if [[ ! -x "$RUST_BIN" ]]; then
  (cd "$REPO_ROOT/rust" && cargo build --release --bin iriq 2>&1 | tail -3)
fi

# Generate 2000 URLs.
INPUT="$(mktemp)"
trap 'rm -f "$INPUT"' EXIT

python3 - <<'EOF' > "$INPUT"
import random
random.seed(42)
hosts = ["foo.com","bar.com","app.example.com","docs.example.com","shop.io"]
verbs = ["users","posts","items","orders","comments","articles","tags","files"]
for _ in range(2000):
    h = random.choice(hosts)
    v = random.choice(verbs)
    seg = random.randint(1, 100000)
    extra = random.choice(["", f"/edit", f"/show", f"/view", f"?page={random.randint(1,50)}"])
    print(f"https://{h}/{v}/{seg}{extra}")
EOF

bytes=$(wc -c < "$INPUT")
echo "Input: $(wc -l < "$INPUT") URLs, ${bytes} bytes"
echo "Running each implementation $ITERS times with -n..."

time_one() {
  local label="$1"; shift
  local cmd=("$@")
  local out=""
  for ((i = 0; i < ITERS; i++)); do
    local start=$(date +%s%N)
    "${cmd[@]}" < "$INPUT" >/dev/null
    local end=$(date +%s%N)
    local ms=$(( (end - start) / 1000000 ))
    out+="$ms "
  done
  local sorted
  sorted=$(echo "$out" | tr ' ' '\n' | grep -v '^$' | sort -n)
  local count
  count=$(echo "$sorted" | wc -l)
  local mid=$((count/2+1))
  local median
  median=$(echo "$sorted" | sed -n "${mid}p")
  printf "  %-6s median=%sms  all=%s\n" "$label" "$median" "$out"
}

time_one "go"   "$GO_BIN"   -n
time_one "rust" "$RUST_BIN" -n
