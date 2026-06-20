#!/usr/bin/env bash
# Three-way parity for the Rust port. Diffs Rust CLI output against the
# Go CLI (which is itself Ruby-parity-tested in CI).
#
# Scoped to Phase 1 scenarios — single-input + pipe modes, JSON + human
# output, no --corpus / --stats / --reinfer / --propose-recognizers.

set -euo pipefail
unset CDPATH

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="${IRIQ_GO_BIN:-$REPO_ROOT/bin/iriq}"
RUST_BIN="${IRIQ_RUST_BIN:-$REPO_ROOT/rust/target/release/iriq}"

if [[ ! -x "$GO_BIN" ]]; then
  echo "Building Go binary..."
  mkdir -p "$(dirname "$GO_BIN")"
  (cd "$REPO_ROOT" && go build -o "$GO_BIN" ./cmd/iriq)
fi
if [[ ! -x "$RUST_BIN" ]]; then
  echo "Building Rust binary (release)..."
  (cd "$REPO_ROOT/rust" && cargo build --release --bin iriq 2>&1 | tail -3)
fi

pass=0
fail=0

run_pair() {
  local label="$1"; local stdin="$2"; shift 2
  local args=("$@")
  local g r
  g=$(echo -n "$stdin" | "$GO_BIN" "${args[@]}" 2>&1 || true)
  r=$(echo -n "$stdin" | "$RUST_BIN" "${args[@]}" 2>&1 || true)
  if [[ "$g" == "$r" ]]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    echo
    echo "MISMATCH: $label"
    echo "  args: ${args[*]}"
    [[ -n "$stdin" ]] && echo "  stdin: $(printf %q "$stdin")"
    diff <(echo "$g") <(echo "$r") | sed 's/^/    /'
  fi
}

# ── Single-input scenarios ─────────────────────────────────────────────
run_pair "version"           "" --version
run_pair "summary URL"       "" "https://foo.com/users/123"
run_pair "summary schemeless" "" "foo.com/users/456"
run_pair "summary URN"       "" "urn:isbn:0451450523"
run_pair "summary unicode"   "" "https://例え.テスト/こんにちは"
run_pair "normalize -n"      "" -n "https://foo.com/users/123"
run_pair "normalize -nN"     "" -n -N "https://foo.com/users/123"
run_pair "canonical -c"      "" -c "foo.com/users/123"
run_pair "canonical -c json" "" -c --json "HTTP://Foo.COM:80/Users/123#frag"
run_pair "canonical+normalize -cn" "" -cn "https://foo.com/users/123"
run_pair "parse -p json"     "" -p --json "https://foo.com/users/123/orders/456"
run_pair "multi-section -pn json"  "" -pn --json "foo.com/users/1?a=1&b=2"
run_pair "multi-section -pc json"  "" -pc --json "foo.com/users/1?a=1&b=2"
run_pair "multi-section -pcn json" "" -pcn --json "foo.com/users/1?x=2&y=3"
run_pair "normalize date path"   "" -n "https://foo.com/events/20240115/details"
run_pair "normalize date param"  "" -n "https://foo.com/events?since=2024/01/15&page=5"
run_pair "normalize network params" "" -n "https://foo.com/admin?ip=192.168.1.1&email=alice@example.com&redirect=https://other.com/x"
run_pair "normalize ipv6 param"  "" -n "https://foo.com/admin?host=2001:db8::1"
run_pair "normalize currency path"  "" -n "https://shop.com/pricing/usd/checkout"
run_pair "normalize currency param" "" -n "https://shop.com/price?currency=eur"
run_pair "normalize ip collapse"    "" -n "https://foo.com/probe/192.168.1.1"
run_pair "normalize version path"   "" -n "https://foo.com/api/v1/status"
run_pair "normalize new types"      "" -n "https://foo.com/upload?type=image/png&token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.dQw4w9WgXcQ&phone=%2B15551234567"
run_pair "normalize file segment"   "" -n "https://foo.com/uploads/image.png"
run_pair "normalize NANP phone"     "" -n "https://foo.com/contact/555-666-7777"
run_pair "normalize param hints"    "" -n "https://foo.com/x?phone=unknown&email=tbd&redirect=somepath"
run_pair "normalize hint vs specific" "" -n "https://foo.com/x?phone=12345"
run_pair "explain version + ip" "" -e "https://foo.com/api/v1/probe/192.168.1.1"
run_pair "explain currency upcase" "" -e "https://shop.com/pricing/usd?currency=eur"
run_pair "explain param-name lift" "" -e "https://foo.com/x?phone=unknown&email=tbd"
run_pair "explain combined parse+explain" "" -pe "https://foo.com/users/123"
run_pair "explain json" "" -e -j "https://foo.com/api/v1/status"
run_pair "normalize color path"    "" -n "https://foo.com/themes/%23ff00ff"
run_pair "normalize color param"   "" -n "https://foo.com/ui?bg=%23ff00ff"
run_pair "normalize coordinate"    "" -n "https://foo.com/m/37.7749,-122.4194"
run_pair "normalize country"       "" -n "https://foo.com/orders?country=US"
run_pair "normalize base64 token"  "" -n "https://foo.com/x?t=TWFuIGlzIGRpc3Rpbmd1aXNoZWQ%3D"

# ── Pipe scenarios ─────────────────────────────────────────────────────
run_pair "pipe URL list" \
  $'https://foo.com/users/1\nhttps://foo.com/users/2\nhttps://foo.com/posts/abc-123/edit\n'
run_pair "pipe duplicates" \
  $'https://foo.com\nhttps://foo.com\nhttps://bar.com\n'
run_pair "pipe -n normalize" \
  "see https://foo.com/users/1 and (https://foo.com/users/2)" -n
run_pair "pipe -c canonical" \
  "see https://foo.com/users/1 and (https://foo.com/users/2)" -c
run_pair "pipe -n --json" \
  "see https://foo.com/users/1 and https://foo.com/users/2" -n --json
run_pair "pipe -n --ndjson" \
  "see https://foo.com/users/1 and https://foo.com/users/2" -n --ndjson
run_pair "pipe -n -J" \
  "see https://foo.com/users/1 and https://foo.com/users/2" -nJ
run_pair "pipe url-list --ndjson" \
  $'https://foo.com\nhttps://foo.com\nhttps://bar.com\n' --ndjson
run_pair "pipe cluster auto" \
  $'https://foo.com/users/1\nhttps://foo.com/users/2\nhttps://foo.com/users/3\nhttps://foo.com/users/4\nhttps://foo.com/users/5\nhttps://foo.com/users/6\nhttps://foo.com/users/7\nhttps://foo.com/users/8\nhttps://foo.com/users/9\nhttps://foo.com/users/10\n'

echo
echo "Passed: $pass"
echo "Failed: $fail"
[[ $fail -eq 0 ]]
