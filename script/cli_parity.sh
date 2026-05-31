#!/usr/bin/env bash
# CLI-level parity check: runs the same inputs through the Ruby and Go
# implementations and reports any mismatches. Exit code 0 means parity holds.
#
#   ./script/cli_parity.sh
#
# Requires: bundler-installed Ruby gem (for `bundle exec exe/iriq`) and a
# built Go binary (built on demand if not present).

set -euo pipefail
unset CDPATH  # don't let user CDPATH leak into our path resolution

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="${IRIQ_GO_BIN:-$REPO_ROOT/bin/iriq}"

if [[ ! -x "$GO_BIN" ]]; then
  echo "Building Go binary at $GO_BIN..."
  mkdir -p "$(dirname "$GO_BIN")"
  # -tags sqlite is required because the parity scenarios include SQLite
  # corpora; the slim default build would error out on .db paths.
  (cd "$REPO_ROOT" && go build -tags sqlite -o "$GO_BIN" ./cmd/iriq)
fi

# Ruby's regex engine refuses UTF-8 pattern + ASCII-8BIT subject mixing, so
# the CLI needs a UTF-8 locale when Unicode arguments flow through ARGV. The
# Go binary doesn't care.
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

  local ruby_out go_out
  ruby_out=$(echo -n "$stdin" | (cd "$REPO_ROOT" && $RUBY "${args[@]}") 2>&1 || true)
  go_out=$(echo -n "$stdin" | "$GO_BIN" "${args[@]}" 2>&1 || true)

  if [[ "$ruby_out" == "$go_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: $label"
    echo "  args:  ${args[*]}"
    if [[ -n "$stdin" ]]; then
      echo "  stdin: $(printf %q "$stdin")"
    fi
    diff <(echo "$ruby_out") <(echo "$go_out") | sed 's/^/    /'
  fi
}

# Single-input forms
run_pair "version"           "" --version
run_pair "summary URL"       "" "https://foo.com/users/123"
run_pair "summary schemeless" "" "foo.com/users/456"
run_pair "summary URN"       "" "urn:isbn:0451450523"
run_pair "normalize -n"      "" -n "https://foo.com/users/123"
run_pair "normalize -nN"     "" -n -N "https://foo.com/users/123"
run_pair "parse -p json"     "" -p --json "https://foo.com/users/123/orders/456"
run_pair "summary unicode"   "" "https://例え.テスト/こんにちは"
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
run_pair "pipe -n --json" \
  "see https://foo.com/users/1 and https://foo.com/users/2" -n --json
run_pair "pipe -n --ndjson" \
  "see https://foo.com/users/1 and https://foo.com/users/2" -n --ndjson
run_pair "pipe -n -J (short ndjson)" \
  "see https://foo.com/users/1 and https://foo.com/users/2" -nJ
run_pair "pipe url-list --ndjson" \
  $'https://foo.com\nhttps://foo.com\nhttps://bar.com\n' --ndjson
run_pair "pipe cluster auto" \
  $'https://foo.com/users/1\nhttps://foo.com/users/2\nhttps://foo.com/users/3\nhttps://foo.com/users/4\nhttps://foo.com/users/5\nhttps://foo.com/users/6\nhttps://foo.com/users/7\nhttps://foo.com/users/8\nhttps://foo.com/users/9\nhttps://foo.com/users/10\n'

# Corpus mode parity — observe the same stream under JSON storage in one run
# and SQLite storage in another, then dump stats from each and diff.
corpus_dir="$(mktemp -d)"
trap "rm -rf '$corpus_dir'" EXIT
corpus_stream=$'https://foo.com/users/1\nhttps://foo.com/users/2\nhttps://foo.com/users/3\nhttps://bar.com/x\n'

corpus_pair() {
  local label="$1" ext="$2"
  local ruby_path="$corpus_dir/ruby$ext"
  local go_path="$corpus_dir/go$ext"
  echo -n "$corpus_stream" | (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path") > /dev/null
  echo -n "$corpus_stream" | "$GO_BIN" --corpus "$go_path" > /dev/null
  # Force piped stdin (closed) so both CLIs treat the second invocation as
  # batch mode → stats path rather than waiting on the terminal.
  local ruby_out go_out
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --stats --json < /dev/null) )
  go_out=$( "$GO_BIN" --corpus "$go_path" --stats --json < /dev/null )
  if [[ "$ruby_out" == "$go_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: corpus $label"
    diff <(echo "$ruby_out") <(echo "$go_out") | sed 's/^/    /'
  fi
}

corpus_pair "JSON storage"   ".json"
corpus_pair "SQLite storage" ".db"

# --reinfer parity. After observing the same stream, both CLIs should
# produce identical --reinfer output, and --stats afterward should still
# match (idempotent replay).
reinfer_pair() {
  local label="$1" ext="$2"
  local ruby_path="$corpus_dir/ruby-rein$ext"
  local go_path="$corpus_dir/go-rein$ext"
  rm -f "$ruby_path" "$go_path"
  echo -n "$corpus_stream" | (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path") > /dev/null
  echo -n "$corpus_stream" | "$GO_BIN" --corpus "$go_path" > /dev/null
  local ruby_out go_out
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --reinfer < /dev/null) )
  go_out=$(   "$GO_BIN" --corpus "$go_path" --reinfer < /dev/null )
  if [[ "$ruby_out" != "$go_out" ]]; then
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: reinfer $label"
    diff <(echo "$ruby_out") <(echo "$go_out") | sed 's/^/    /'
    return
  fi
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --stats --json < /dev/null) )
  go_out=$(   "$GO_BIN" --corpus "$go_path" --stats --json < /dev/null )
  if [[ "$ruby_out" == "$go_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: reinfer-stats $label"
    diff <(echo "$ruby_out") <(echo "$go_out") | sed 's/^/    /'
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
  local go_path="$corpus_dir/go-propose$ext"
  rm -f "$ruby_path" "$go_path"
  local propose_stream=""
  for i in $(seq 1 25); do
    propose_stream+="https://api.github.com/auth/ghp_aaaa$(printf '%04d' "$i")xyzzy"$'\n'
  done
  echo -n "$propose_stream" | (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path") > /dev/null
  echo -n "$propose_stream" | "$GO_BIN" --corpus "$go_path" > /dev/null
  local ruby_out go_out
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --propose-recognizers < /dev/null) )
  go_out=$(   "$GO_BIN" --corpus "$go_path" --propose-recognizers < /dev/null )
  if [[ "$ruby_out" != "$go_out" ]]; then
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: propose-recognizers $label (human)"
    diff <(echo "$ruby_out") <(echo "$go_out") | sed 's/^/    /'
    return
  fi
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --propose-recognizers --json < /dev/null) )
  go_out=$(   "$GO_BIN" --corpus "$go_path" --propose-recognizers --json < /dev/null )
  if [[ "$ruby_out" == "$go_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: propose-recognizers $label (json)"
    diff <(echo "$ruby_out") <(echo "$go_out") | sed 's/^/    /'
  fi
}

propose_pair "JSON storage"   ".json"
propose_pair "SQLite storage" ".db"

# Completion-subcommand parity. Both runtimes embed the same files; the
# parity test ensures we don't ship divergent scripts.
completion_pair() {
  local shell="$1"
  local ruby_out go_out
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY completion "$shell") )
  go_out=$(   "$GO_BIN" completion "$shell" )
  if [[ "$ruby_out" == "$go_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: completion $shell"
    diff <(echo "$ruby_out") <(echo "$go_out") | sed 's/^/    /'
  fi
}

completion_pair "bash"
completion_pair "zsh"

# --host=reg should cluster subdomain-heavy hosts under their registrable apex.
host_strategy_pair() {
  local label="$1"
  local rstream=$'https://api.foo.com/users/1\nhttps://app.foo.com/users/2\nhttps://blog.example.co.uk/posts/3\nhttps://news.example.co.uk/posts/4\n'
  local ruby_path="$corpus_dir/ruby-host.json"
  local go_path="$corpus_dir/go-host.json"
  rm -f "$ruby_path" "$go_path"
  echo -n "$rstream" | (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --host=reg) > /dev/null
  echo -n "$rstream" | "$GO_BIN" --corpus "$go_path" --host=reg > /dev/null
  local ruby_out go_out
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --stats --json < /dev/null) )
  go_out=$( "$GO_BIN" --corpus "$go_path" --stats --json < /dev/null )
  if [[ "$ruby_out" == "$go_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: $label"
    diff <(echo "$ruby_out") <(echo "$go_out") | sed 's/^/    /'
  fi
}
host_strategy_pair "--host=reg collapses subdomains"

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
if [[ $fail_count -gt 0 ]]; then
  exit 1
fi
