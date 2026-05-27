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

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
if [[ $fail_count -gt 0 ]]; then
  exit 1
fi
