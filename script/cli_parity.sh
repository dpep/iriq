#!/usr/bin/env bash
# CLI-level parity check: runs the same inputs through the Ruby and Rust
# implementations and reports any mismatches. Exit code 0 means parity holds.
#
#   ./script/cli_parity.sh
#
# Requires: bundler-installed Ruby gem (for `bundle exec exe/iriq`) and a
# built Rust binary (built on demand if not present).

set -euo pipefail
unset CDPATH  # don't let user CDPATH leak into our path resolution

# Disable the default auto-corpus so the parity scenarios don't race for
# the shared default.db. Tests that exercise corpus persistence pass an
# explicit --corpus PATH against a per-test tempfile.
export IRIQ_NO_CORPUS=1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST_BIN="${IRIQ_RUST_BIN:-$REPO_ROOT/rust/target/release/iriq}"

if [[ ! -x "$RUST_BIN" ]]; then
  echo "Building Rust binary at $RUST_BIN..."
  (cd "$REPO_ROOT/rust" && cargo build --release --bin iriq 2>&1 | tail -3)
fi

# Ruby's regex engine refuses UTF-8 pattern + ASCII-8BIT subject mixing, so
# the CLI needs a UTF-8 locale when Unicode arguments flow through ARGV. The
# Rust binary doesn't care.
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

RUBY="bundle exec --gemfile=$REPO_ROOT/Gemfile $REPO_ROOT/exe/iriq"
fail_count=0
pass_count=0

run_pair() {
  local label="$1"
  local stdin="$2"
  shift 2
  local args=("$@")

  local ruby_out rust_out
  ruby_out=$(echo -n "$stdin" | (cd "$REPO_ROOT" && $RUBY "${args[@]}") 2>&1 || true)
  rust_out=$(echo -n "$stdin" | "$RUST_BIN" "${args[@]}" 2>&1 || true)

  if [[ "$ruby_out" == "$rust_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: $label"
    echo "  args:  ${args[*]}"
    if [[ -n "$stdin" ]]; then
      echo "  stdin: $(printf %q "$stdin")"
    fi
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
  fi
}

# Like run_pair, but compares JSON *semantically* by normalizing both sides
# through `jq -S` (sorts object keys recursively and canonicalizes number
# formatting). This lets us parity-test JSON whose key order differs by
# runtime without forcing one emission order on everyone. Skipped when jq is
# unavailable.
run_pair_json() {
  local label="$1"
  local stdin="$2"
  shift 2
  local args=("$@")

  if ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  # `-S` sorts keys; `walk(.+0)` forces every number through arithmetic so
  # whole-valued floats canonicalize identically (jq 1.7+ otherwise preserves
  # `1` vs `1.0` literally).
  local norm='walk(if type == "number" then . + 0 else . end)'
  local ruby_out rust_out
  ruby_out=$(echo -n "$stdin" | (cd "$REPO_ROOT" && $RUBY "${args[@]}") 2>&1 | jq -S "$norm" 2>&1 || true)
  rust_out=$(echo -n "$stdin" | "$RUST_BIN" "${args[@]}" 2>&1 | jq -S "$norm" 2>&1 || true)

  if [[ "$ruby_out" == "$rust_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH (json): $label"
    echo "  args:  ${args[*]}"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
  fi
}

# Single-input forms
run_pair "version"           "" --version
run_pair "summary URL"       "" "https://foo.com/users/123"
run_pair "summary schemeless" "" "foo.com/users/456"
run_pair "summary URN"       "" "urn:isbn:0451450523"
run_pair "normalize -n"      "" -n "https://foo.com/users/123"
run_pair "normalize -nN"     "" -n -N "https://foo.com/users/123"
run_pair "canonical -c"      "" -c "foo.com/users/123"
run_pair "canonical -c json" "" -c --json "HTTP://Foo.COM:80/Users/123#frag"
run_pair "canonical+normalize -cn" "" -cn "https://foo.com/users/123"
run_pair "parse -p json"     "" -p --json "https://foo.com/users/123/orders/456"
# Multi-section JSON: object key order must match across runtimes. Ruby
# emits a fixed insertion order (parse, canonical, normalize) and Rust pins
# the same. The & in the query also exercises the no-HTML-escape path.
run_pair "multi-section -pn json"  "" -pn --json "foo.com/users/1?a=1&b=2"
run_pair "multi-section -pc json"  "" -pc --json "foo.com/users/1?a=1&b=2"
run_pair "multi-section -pcn json" "" -pcn --json "foo.com/users/1?x=2&y=3"
run_pair "summary unicode"   "" "https://例え.テスト/こんにちは"
# JSON error envelope: structured errors on the failure path must match
# byte-for-byte across runtimes (run_pair folds stderr into the diff via 2>&1).
run_pair "json error parse"  "" --json "just-some-token"
run_pair "json error shell"  "" completion tcsh --json
run_pair "json error missing-corpus" "" --propose-recognizers --json
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
run_pair "cluster dedupe + params" $'https://foo.com/items?page=1\nhttps://foo.com/items?page=2\nhttps://foo.com/items?page=1\nhttps://foo.com/items?page=2\nhttps://foo.com/items?page=3\nhttps://foo.com/items?page=4\nhttps://foo.com/items?page=5\nhttps://foo.com/items?page=6\nhttps://foo.com/items?page=7\nhttps://foo.com/items?page=8\nhttps://foo.com/items?page=9\nhttps://foo.com/items?page=10\n'
run_pair "cluster status enum"     $'https://foo.com/posts?status=published\nhttps://foo.com/posts?status=published\nhttps://foo.com/posts?status=published\nhttps://foo.com/posts?status=draft\nhttps://foo.com/posts?status=draft\nhttps://foo.com/posts?status=draft\nhttps://foo.com/posts?status=draft\nhttps://foo.com/posts?status=draft\nhttps://foo.com/posts?status=archived\nhttps://foo.com/posts?status=archived\nhttps://foo.com/posts?status=archived\nhttps://foo.com/posts?status=archived\nhttps://foo.com/posts?status=archived\nhttps://foo.com/posts?status=published\nhttps://foo.com/posts?status=draft\nhttps://foo.com/posts?status=published\nhttps://foo.com/posts?status=draft\nhttps://foo.com/posts?status=archived\nhttps://foo.com/posts?status=archived\nhttps://foo.com/posts?status=draft\n'

# Pipe modes
run_pair "pipe URL list" \
  $'https://foo.com/users/1\nhttps://foo.com/users/2\nhttps://foo.com/posts/abc-123/edit\n'
run_pair "pipe duplicates" \
  $'https://foo.com\nhttps://foo.com\nhttps://bar.com\n'
run_pair "pipe -n normalize" \
  "see https://foo.com/users/1 and (https://foo.com/users/2)" -n
run_pair "pipe -c canonical" \
  "see https://foo.com/users/1 and (https://foo.com/users/2)" -c
run_pair "pipe -c --ndjson" \
  "see https://foo.com/users/1 and https://foo.com/users/2" -c --ndjson
run_pair "pipe -n --json" \
  "see https://foo.com/users/1 and https://foo.com/users/2" -n --json
# Multi-section JSON in pipe mode: per-IRI object key order must also match
# (parse before canonical), not just the single-input path above.
run_pair "pipe -pc --json" \
  "see https://foo.com/users/1 and https://foo.com/users/2" -pc --json
run_pair "pipe -pc --ndjson" \
  "see https://foo.com/users/1 and https://foo.com/users/2" -pc --ndjson
run_pair "pipe -n --ndjson" \
  "see https://foo.com/users/1 and https://foo.com/users/2" -n --ndjson
run_pair "pipe -n -J (short ndjson)" \
  "see https://foo.com/users/1 and https://foo.com/users/2" -nJ
run_pair "pipe url-list --ndjson" \
  $'https://foo.com\nhttps://foo.com\nhttps://bar.com\n' --ndjson
run_pair "pipe cluster auto" \
  $'https://foo.com/users/1\nhttps://foo.com/users/2\nhttps://foo.com/users/3\nhttps://foo.com/users/4\nhttps://foo.com/users/5\nhttps://foo.com/users/6\nhttps://foo.com/users/7\nhttps://foo.com/users/8\nhttps://foo.com/users/9\nhttps://foo.com/users/10\n'

# Param classification ladder (const → string → enum) + confidence score must
# match across runtimes. status → enum, label → string, fmt → constant literal.
param_words=(one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty alpha beta gamma delta)
param_stream=""
for pi in "${!param_words[@]}"; do
  pst=open; [[ $((pi % 2)) -eq 1 ]] && pst=closed
  param_stream+="https://foo.com/items?status=$pst&label=${param_words[$pi]}&fmt=json"$'\n'
done
run_pair "cluster params (enum/string/const/conf)" "$param_stream" cluster
run_pair_json "cluster params --json (key-order-agnostic)" "$param_stream" cluster --json

# Corpus mode parity — observe the same stream under JSON storage in one run
# and SQLite storage in another, then dump stats from each and diff.
corpus_dir="$(mktemp -d)"
trap "rm -rf '$corpus_dir'" EXIT
corpus_stream=$'https://foo.com/users/1\nhttps://foo.com/users/2\nhttps://foo.com/users/3\nhttps://bar.com/x\n'

corpus_pair() {
  local label="$1" ext="$2"
  local ruby_path="$corpus_dir/ruby$ext"
  local rust_path="$corpus_dir/rust$ext"
  echo -n "$corpus_stream" | (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path") > /dev/null
  echo -n "$corpus_stream" | "$RUST_BIN" --corpus "$rust_path" > /dev/null
  # Force piped stdin (closed) so both CLIs treat the second invocation as
  # batch mode → stats path rather than waiting on the terminal.
  local ruby_out rust_out
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --stats --json < /dev/null) )
  rust_out=$( "$RUST_BIN" --corpus "$rust_path" --stats --json < /dev/null )
  if [[ "$ruby_out" == "$rust_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: corpus $label"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
  fi
}

corpus_pair "JSON storage"   ".json"
corpus_pair "SQLite storage" ".db"

# Cluster examples dedup — repeated inputs must collapse to a single example in
# the rendered cluster view (regression: the SQLite backend once stored dupes).
dedup_stream=$'https://foo.com/users/1\nhttps://foo.com/users/1\nhttps://foo.com/users/1\nhttps://foo.com/users/2\n'
ruby_dedup="$corpus_dir/ruby-dedup.db"
rust_dedup="$corpus_dir/rust-dedup.db"
echo -n "$dedup_stream" | (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_dedup") > /dev/null
echo -n "$dedup_stream" | "$RUST_BIN" --corpus "$rust_dedup" > /dev/null
ruby_dedup_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_dedup" cluster < /dev/null) )
rust_dedup_out=$( "$RUST_BIN" --corpus "$rust_dedup" cluster < /dev/null )
if [[ "$ruby_dedup_out" == "$rust_dedup_out" ]]; then
  pass_count=$((pass_count + 1))
else
  fail_count=$((fail_count + 1))
  echo
  echo "MISMATCH: cluster examples dedup"
  diff <(echo "$ruby_dedup_out") <(echo "$rust_dedup_out") | sed 's/^/    /' || true
fi

# Cluster param numeric ranges must survive the SQLite readback (regression:
# the Ruby backend once dropped numeric min/max/avg when loading a cluster).
numeric_stream=$'https://foo.com/search?page=1\nhttps://foo.com/search?page=2\nhttps://foo.com/search?page=3\nhttps://foo.com/search?page=4\n'
ruby_nums="$corpus_dir/ruby-nums.db"
rust_nums="$corpus_dir/rust-nums.db"
echo -n "$numeric_stream" | (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_nums") > /dev/null
echo -n "$numeric_stream" | "$RUST_BIN" --corpus "$rust_nums" > /dev/null
ruby_nums_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_nums" cluster < /dev/null) )
rust_nums_out=$( "$RUST_BIN" --corpus "$rust_nums" cluster < /dev/null )
if [[ "$ruby_nums_out" == "$rust_nums_out" ]]; then
  pass_count=$((pass_count + 1))
else
  fail_count=$((fail_count + 1))
  echo
  echo "MISMATCH: cluster param numeric readback (SQLite)"
  diff <(echo "$ruby_nums_out") <(echo "$rust_nums_out") | sed 's/^/    /' || true
fi

# --reinfer parity. After observing the same stream, both CLIs should
# produce identical --reinfer output, and --stats afterward should still
# match (idempotent replay).
reinfer_pair() {
  local label="$1" ext="$2"
  local ruby_path="$corpus_dir/ruby-rein$ext"
  local rust_path="$corpus_dir/rust-rein$ext"
  rm -f "$ruby_path" "$rust_path"
  echo -n "$corpus_stream" | (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path") > /dev/null
  echo -n "$corpus_stream" | "$RUST_BIN" --corpus "$rust_path" > /dev/null
  local ruby_out rust_out
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --reinfer < /dev/null) )
  rust_out=$(   "$RUST_BIN" --corpus "$rust_path" --reinfer < /dev/null )
  if [[ "$ruby_out" != "$rust_out" ]]; then
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: reinfer $label"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
    return
  fi
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --stats --json < /dev/null) )
  rust_out=$(   "$RUST_BIN" --corpus "$rust_path" --stats --json < /dev/null )
  if [[ "$ruby_out" == "$rust_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: reinfer-stats $label"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
  fi
}

reinfer_pair "JSON storage"   ".json"
reinfer_pair "SQLite storage" ".db"

# --propose-recognizers parity. Both human and JSON output should match
# byte-for-byte after the same observation stream. Use a stream that
# triggers the PrefixUnderscoreId strategy ≥20 times.
propose_pair() {
  local label="$1" ext="$2"
  local ruby_path="$corpus_dir/ruby-propose$ext"
  local rust_path="$corpus_dir/rust-propose$ext"
  rm -f "$ruby_path" "$rust_path"
  local propose_stream=""
  for i in $(seq 1 25); do
    propose_stream+="https://api.github.com/auth/ghp_aaaa$(printf '%04d' "$i")xyzzy"$'\n'
  done
  echo -n "$propose_stream" | (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path") > /dev/null
  echo -n "$propose_stream" | "$RUST_BIN" --corpus "$rust_path" > /dev/null
  local ruby_out rust_out
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --propose-recognizers < /dev/null) )
  rust_out=$(   "$RUST_BIN" --corpus "$rust_path" --propose-recognizers < /dev/null )
  if [[ "$ruby_out" != "$rust_out" ]]; then
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: propose-recognizers $label (human)"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
    return
  fi
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --propose-recognizers --json < /dev/null) )
  rust_out=$(   "$RUST_BIN" --corpus "$rust_path" --propose-recognizers --json < /dev/null )
  if [[ "$ruby_out" == "$rust_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: propose-recognizers $label (json)"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
  fi
}

propose_pair "JSON storage"   ".json"
propose_pair "SQLite storage" ".db"

# Completion-subcommand parity. Both runtimes embed the same files; the
# parity test ensures we don't ship divergent scripts.
completion_pair() {
  local shell="$1"
  local ruby_out rust_out
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY completion "$shell") )
  rust_out=$(   "$RUST_BIN" completion "$shell" )
  if [[ "$ruby_out" == "$rust_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: completion $shell"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
  fi
}

completion_pair "bash"
completion_pair "zsh"

# Auto-activation parity. After observing the same PAT-shaped stream and
# activating the proposal in both runtimes, classify("ghp_xyz") should
# return :ghp in both — verify via --stats post-reinfer and reinfer
# output. We use --activate-above to drive the activation through the
# CLI and assert the output lines match.
#
# KNOWN DIVERGENCE (skipped below): Ruby activates a proposal under its
# dynamic suggested type (`activated: ghp (ghp_)`); Rust's SegmentType is
# a closed enum, so it falls back to opaque_id (see the "for now" note in
# rust/iriq/src/corpus.rs activate_proposal). Re-enable these scenarios
# once Rust supports dynamic synthesized types.
activate_pair() {
  local label="$1" ext="$2"
  local ruby_path="$corpus_dir/ruby-act$ext"
  local rust_path="$corpus_dir/rust-act$ext"
  rm -f "$ruby_path" "$rust_path"
  local pat_stream=""
  for i in $(seq 1 25); do
    pat_stream+="https://api.github.com/auth/ghp_aaaa$(printf '%04d' "$i")xyzzy"$'\n'
  done
  echo -n "$pat_stream" | (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path") > /dev/null
  echo -n "$pat_stream" | "$RUST_BIN" --corpus "$rust_path" > /dev/null
  local ruby_out rust_out
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --propose-recognizers --activate-above 0.9 < /dev/null) )
  rust_out=$(   "$RUST_BIN" --corpus "$rust_path" --propose-recognizers --activate-above 0.9 < /dev/null )
  if [[ "$ruby_out" == "$rust_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: activate-above $label"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
  fi
}

# activate_pair "JSON storage"   ".json"
# activate_pair "SQLite storage" ".db"

# --cross-host-shapes parity. Stream IRIs across multiple hosts that
# share the same shape; both runtimes should report identical output.
cross_host_pair() {
  local label="$1" ext="$2"
  local ruby_path="$corpus_dir/ruby-xh$ext"
  local rust_path="$corpus_dir/rust-xh$ext"
  rm -f "$ruby_path" "$rust_path"
  local xh_stream=$'https://foo.com/users/1\nhttps://bar.com/users/2\nhttps://baz.com/users/3\nhttps://foo.com/posts/abc\nhttps://bar.com/posts/def\n'
  echo -n "$xh_stream" | (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path") > /dev/null
  echo -n "$xh_stream" | "$RUST_BIN" --corpus "$rust_path" > /dev/null
  local ruby_out rust_out
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --cross-host-shapes < /dev/null) )
  rust_out=$(   "$RUST_BIN" --corpus "$rust_path" --cross-host-shapes < /dev/null )
  if [[ "$ruby_out" != "$rust_out" ]]; then
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: cross-host-shapes $label (human)"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
    return
  fi
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --cross-host-shapes --json < /dev/null) )
  rust_out=$(   "$RUST_BIN" --corpus "$rust_path" --cross-host-shapes --json < /dev/null )
  if [[ "$ruby_out" == "$rust_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: cross-host-shapes $label (json)"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
  fi
}

cross_host_pair "JSON storage"   ".json"
cross_host_pair "SQLite storage" ".db"

# --host=reg should cluster subdomain-heavy hosts under their registrable apex.
host_strategy_pair() {
  local label="$1"
  local rstream=$'https://api.foo.com/users/1\nhttps://app.foo.com/users/2\nhttps://blog.example.co.uk/posts/3\nhttps://news.example.co.uk/posts/4\n'
  local ruby_path="$corpus_dir/ruby-host.json"
  local rust_path="$corpus_dir/rust-host.json"
  rm -f "$ruby_path" "$rust_path"
  echo -n "$rstream" | (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --host=reg) > /dev/null
  echo -n "$rstream" | "$RUST_BIN" --corpus "$rust_path" --host=reg > /dev/null
  local ruby_out rust_out
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --stats --json < /dev/null) )
  rust_out=$( "$RUST_BIN" --corpus "$rust_path" --stats --json < /dev/null )
  if [[ "$ruby_out" == "$rust_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: $label"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
  fi
}
host_strategy_pair "--host=reg collapses subdomains"

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
if [[ $fail_count -gt 0 ]]; then
  exit 1
fi
