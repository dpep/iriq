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

# Usage / help — the full USAGE text must match byte-for-byte (the Rust
# CLI inlines a copy of Ruby's USAGE heredoc; keep them in sync).
run_pair "help" "" --help
# Bare invocation. The harness always pipes stdin, so this exercises the
# empty-batch path (no output) rather than the tty usage path.
run_pair "usage no args" ""

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
# Human parse dump renders query_params via Ruby Hash#inspect: insertion
# order, spaced arrows, nil for a valueless param ("?flag") vs "" ("?flag=").
run_pair "parse -p human params" "" -p "https://foo.com/x?flag&a=1&b="
run_pair "parse -p json params"  "" -p --json "https://foo.com/x?flag&a=1&b="
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
run_pair "json error host bogus" "" --host bogus --json "foo.com/x"
# Human (non-JSON) error paths — the plain "iriq: ..." stderr lines must
# also match, not just the --json envelopes above.
run_pair "human error parse"          "" "just-some-token"
run_pair "human error unknown option" "" --bogus "foo.com/x"
run_pair "human error unknown short"  "" -z "foo.com/x"
run_pair "human error shell"          "" completion tcsh
run_pair "human error missing-corpus" "" --propose-recognizers
# Ruby's OptionParser reports the space and = forms differently — both quirks
# are mirrored in the Rust CLI.
run_pair "human error host bogus"     "" --host bogus "foo.com/x"
run_pair "human error host=bogus"     "" --host=bogus "foo.com/x"
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

# File-arg auto-detection: a positional arg that is an existing file (and not
# a parseable IRI) is read and extracted, same as piped text. Also the `-`
# stdin sentinel: `cluster -` reads stdin; a bare `-n -` positional is NOT a
# file and falls through to summary mode (a parse error in both runtimes).
url_file="$corpus_dir/urls.txt"
printf 'https://foo.com/users/1\nhttps://foo.com/users/2\nhttps://foo.com/posts/abc\n' > "$url_file"
run_pair "file arg url list" "" "$url_file"
run_pair "file arg cluster"  "" cluster "$url_file"
run_pair "file arg -n"       "" -n "$url_file"
run_pair "stdin sentinel cluster -" $'https://foo.com/users/1\nhttps://foo.com/users/2\n' cluster -
run_pair "stdin sentinel -n -" $'https://foo.com/users/1\n' -n -

# Explain rows agree with the normalized line for already-canonical values,
# and JSON omits fields that don't apply (host on a URN) rather than null.
run_pair "explain already-canonical date+currency" "" -e "https://a.com/events/2024-01-15/USD?currency=EUR"
run_pair "explain json urn omits host"             "" -e -j "urn:isbn:0451450523"
run_pair "normalize currency ascii-only upcase"    "" -n "https://shop.com/price?currency=uſd"

# Corpus-backed single runs: each runtime gets its own fresh corpus file. The
# "created corpus at PATH" notice embeds that per-side path, so only stdout is
# compared here.
fresh_corpus_pair() {
  local label="$1" stdin="$2" ext="$3"
  shift 3
  local ruby_path="$corpus_dir/ruby-fresh$ext"
  local rust_path="$corpus_dir/rust-fresh$ext"
  rm -f "$ruby_path" "$ruby_path-wal" "$ruby_path-shm" "$rust_path" "$rust_path-wal" "$rust_path-shm"
  local ruby_out rust_out
  ruby_out=$(echo -n "$stdin" | (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" "$@") 2>/dev/null || true)
  rust_out=$(echo -n "$stdin" | "$RUST_BIN" --corpus "$rust_path" "$@" 2>/dev/null || true)
  if [[ "$ruby_out" == "$rust_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: $label"
    echo "  args:  $*"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
  fi
}

# -N is honored with a corpus, and a first observation renders exactly as -C
# (currency upcase, param-name hints, no single-sample stable literals).
fresh_corpus_pair "corpus -n -N keeps hints off" "" .db -n -N "https://foo.com/users/123"
fresh_corpus_pair "corpus first observation matches -C" "" .db -n "https://shop.com/pricing/usd?currency=eur&phone=unknown"
fresh_corpus_pair "corpus first observation slug/version match -C" "" .db -n "https://foo.com/api/v1/posts/abc-123"

# Pipe-mode sections observe each IRI, then render it from the corpus as it
# stands: on a cold corpus the first lines print as -C would, and a slot turns
# into a placeholder only once it has the evidence.
cold_names=(alice bob carol dave eve frank grace heidi ivan judy ken leo mary ned olive peg quinn rose sam tom uma vic wade xena yara zoe)
cold_stream=""
for n in "${cold_names[@]}"; do cold_stream+="https://foo.com/users/$n/profile"$'\n'; done
fresh_corpus_pair "pipe -n cold corpus renders as it goes" "$cold_stream" .db -n
fresh_corpus_pair "pipe -n -N cold corpus"                 "$cold_stream" .json -n -N
# Pipe -e prints each IRI's trace, as single-input -e does.
run_pair "pipe -e explain"      "see https://foo.com/users/1 and https://shop.com/pricing/usd" -e
run_pair "pipe -e --json"       "see https://foo.com/users/1 and https://shop.com/pricing/usd" -e --json
run_pair "pipe -ne --ndjson"    "see https://foo.com/users/1" -ne --ndjson

# Numeric params too long to be finite: excluded from min/max/avg, no crash,
# and the JSON corpus still saves.
huge=$(printf '1%.0s' {1..400})
inf_stream="https://inf.com/p?v=$huge"$'\n'"https://inf.com/p?v=-$huge"$'\n'"https://inf.com/p?v=3"$'\n'
fresh_corpus_pair "cluster -j non-finite numeric (json corpus)" "$inf_stream" .json cluster -j
fresh_corpus_pair "cluster human non-finite numeric"            "$inf_stream" .json cluster

# A bare filename (no ./) that exists is read as a file. Both runtimes must run
# from the same directory for the relative name to resolve, so this can't use
# run_pair (which runs Ruby from REPO_ROOT).
bare_file_pair() {
  local label="$1"
  shift
  local ruby_out rust_out
  ruby_out=$( (cd "$corpus_dir" && $RUBY -C "$@" < /dev/null) 2>&1 || true )
  rust_out=$( (cd "$corpus_dir" && "$RUST_BIN" -C "$@" < /dev/null) 2>&1 || true )
  if [[ "$ruby_out" == "$rust_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: $label"
    echo "  args:  $*"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
  fi
}
bare_file_pair "bare filename -n"      -n urls.txt
bare_file_pair "bare filename --stats" urls.txt --stats

# Missing files say so (path-like argument, or anything after `cluster`).
run_pair "missing ./file"            "" -C ./definitely-missing.txt
run_pair "missing /file -n"          "" -C -n /definitely/missing.log
run_pair "missing cluster file json" "" -C --json cluster ./definitely-missing.txt

# Invalid UTF-8 input is a clean error, streaming or slurped, human or JSON.
bad_utf8=$'https://foo.com/users/1\nhttps://foo.com/\xff/x\n'
run_pair "invalid utf-8 stdin -n"        "$bad_utf8" -C -n
run_pair "invalid utf-8 stdin url list"  "$bad_utf8" -C
run_pair "invalid utf-8 stdin json"      "$bad_utf8" -C --json -n

# Input that can't be read is the OS error in io::Error's words. A file iriq
# may not read (skipped where permissions aren't enforced, e.g. root), and
# stdin that is a directory.
printf 'https://foo.com/users/1\n' > "$corpus_dir/noread.txt"
chmod 000 "$corpus_dir/noread.txt"
if [[ ! -r "$corpus_dir/noread.txt" ]]; then
  run_pair "unreadable file arg"      "" -C "$corpus_dir/noread.txt"
  run_pair "unreadable file arg -n"   "" -C -n "$corpus_dir/noread.txt"
  run_pair "unreadable file arg json" "" -C --json cluster "$corpus_dir/noread.txt"
fi
dir_stdin_pair() {
  local label="$1"
  shift
  local ruby_out rust_out
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY "$@" < "$corpus_dir") 2>&1 || true )
  rust_out=$( "$RUST_BIN" "$@" < "$corpus_dir" 2>&1 || true )
  if [[ "$ruby_out" == "$rust_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: $label"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
  fi
}
dir_stdin_pair "stdin is a directory"         -C
dir_stdin_pair "stdin is a directory -n json" -C -n --json

# Corpus files iriq refuses: a JSON object with no corpus keys (left
# untouched), and a SQLite corpus from a newer schema.
printf '{"foo": 1}' > "$corpus_dir/notes.json"
run_pair "refuse non-corpus json"      "" --corpus "$corpus_dir/notes.json" -n "https://foo.com/x"
# Recreate it: a runtime that wrongly accepts the file also overwrites it.
printf '{"foo": 1}' > "$corpus_dir/notes.json"
run_pair "refuse non-corpus json json" "" --json --corpus "$corpus_dir/notes.json" -n "https://foo.com/x"
if [[ "$(cat "$corpus_dir/notes.json")" == '{"foo": 1}' ]]; then
  pass_count=$((pass_count + 1))
else
  fail_count=$((fail_count + 1))
  echo; echo "MISMATCH: refused non-corpus json was modified"
fi
(cd "$REPO_ROOT" && bundle exec ruby -rsqlite3 -e '
  db = SQLite3::Database.new(ARGV[0])
  db.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
  db.execute("INSERT INTO meta VALUES (?, ?)", ["schema_version", "99"])
' "$corpus_dir/future.db")
run_pair "refuse newer sqlite schema" "" --corpus "$corpus_dir/future.db" -n "https://foo.com/x"
run_pair "refuse newer sqlite schema json" "" --json --corpus "$corpus_dir/future.db" -n "https://foo.com/x"
printf '{"host_counts": ' > "$corpus_dir/broken.json"
run_pair "refuse malformed json" "" --corpus "$corpus_dir/broken.json" -n "https://foo.com/x"
# A write SQLite refuses reads like every other corpus failure. Skipped where
# permissions aren't enforced (root).
echo -n "https://x.com/users/1" | "$RUST_BIN" --corpus "$corpus_dir/ro.db" > /dev/null 2>&1
chmod 444 "$corpus_dir/ro.db"
if [[ ! -w "$corpus_dir/ro.db" ]]; then
  run_pair "read-only sqlite corpus"      "" --corpus "$corpus_dir/ro.db" -n "https://x.com/users/2"
  run_pair "read-only sqlite corpus json" "" --json --corpus "$corpus_dir/ro.db" -n "https://x.com/users/2"
fi

# A .db path whose directory exists but is read-only: mkdir_p is a no-op (the
# dir is already there), so the failure surfaces from the open itself. Ruby
# must not announce a corpus it never actually opened. Skipped where
# permissions aren't enforced (root).
mkdir -p "$corpus_dir/readonly"
chmod 555 "$corpus_dir/readonly"
if [[ ! -w "$corpus_dir/readonly" ]]; then
  run_pair "unopenable db in read-only dir"      "" --corpus "$corpus_dir/readonly/c.db" -n "https://x.com/users/1"
  run_pair "unopenable db in read-only dir json" "" --json --corpus "$corpus_dir/readonly/c.db" -n "https://x.com/users/1"
fi
chmod 755 "$corpus_dir/readonly"

# An unopenable `.db` that's actually a directory: the path should appear
# exactly once in the error message in both the human and --json forms.
mkdir -p "$corpus_dir/dir.db"
dir_as_db_pair() {
  local label="$1"
  shift
  local ruby_out rust_out
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY "$@") 2>&1 || true )
  rust_out=$( "$RUST_BIN" "$@" 2>&1 || true )
  if [[ "$ruby_out" != "$rust_out" ]]; then
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: $label"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
    return
  fi
  local occurrences
  occurrences=$(grep -o "$corpus_dir/dir.db" <<<"$ruby_out" | wc -l | tr -d ' ')
  if [[ "$occurrences" == "1" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: $label (path appeared $occurrences times, want 1)"
    echo "  $ruby_out"
  fi
}
dir_as_db_pair "directory named .db (human)" --corpus "$corpus_dir/dir.db" -n "https://x.com/users/1"
dir_as_db_pair "directory named .db (json)"  --json --corpus "$corpus_dir/dir.db" -n "https://x.com/users/1"

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

# --reset parity. Seed a corpus, reset it, and compare the stderr notice.
# Each side seeds + resets the same path in turn so the message (which
# embeds the path) is identical. --json does not change --reset output.
reset_pair() {
  local label="$1"
  shift
  local path="$corpus_dir/reset.db"
  local ruby_out rust_out
  rm -f "$path" "$path-wal" "$path-shm" "$path.tmp"
  echo -n "$corpus_stream" | (cd "$REPO_ROOT" && $RUBY --corpus "$path") > /dev/null
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --reset --corpus "$path" "$@" < /dev/null) 2>&1 || true )
  rm -f "$path" "$path-wal" "$path-shm" "$path.tmp"
  echo -n "$corpus_stream" | "$RUST_BIN" --corpus "$path" > /dev/null
  rust_out=$( "$RUST_BIN" --reset --corpus "$path" "$@" < /dev/null 2>&1 || true )
  if [[ "$ruby_out" == "$rust_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: reset $label"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
  fi
}

reset_pair "seeded (human)"
reset_pair "seeded (--json)" --json

# --reset removes the JSON writer's PATH.<pid>.<n>.tmp leftovers and nothing
# else that merely shares the prefix. Same directory for both sides, so the
# notice (which embeds the path) is comparable.
reset_sweep_side() {
  local dir="$corpus_dir/sweep"
  rm -rf "$dir" && mkdir -p "$dir"
  for f in c.json c.json.tmp c.json.4242.0.tmp c.json.4242.17.tmp c.json.notes c.json.4242.tmp c.json.x.0.tmp c.jsonx.1.0.tmp c.json.0123456789abcdef.tmp; do
    : > "$dir/$f"
  done
  "$@" --reset --corpus "$dir/c.json" < /dev/null 2>&1 || true
  ls "$dir"
}
ruby_sweep=$(cd "$REPO_ROOT" && reset_sweep_side $RUBY)
rust_sweep=$(reset_sweep_side "$RUST_BIN")
if [[ "$ruby_sweep" == "$rust_sweep" ]]; then
  pass_count=$((pass_count + 1))
else
  fail_count=$((fail_count + 1))
  echo; echo "MISMATCH: reset sweeps writer temp files"
  diff <(echo "$ruby_sweep") <(echo "$rust_sweep") | sed 's/^/    /' || true
fi
# The "no corpus to reset" branch — the path never existed. --reset does not
# create the file, so both invocations see the same missing path.
run_pair "reset nonexistent"      "" --reset --corpus "$corpus_dir/never-created.db"
run_pair "reset nonexistent json" "" --reset --json --corpus "$corpus_dir/never-created.db"

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
  shift 2
  local extra=("$@")
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
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --propose-recognizers "${extra[@]}" < /dev/null) )
  rust_out=$(   "$RUST_BIN" --corpus "$rust_path" --propose-recognizers "${extra[@]}" < /dev/null )
  if [[ "$ruby_out" != "$rust_out" ]]; then
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: propose-recognizers $label (human)"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
    return
  fi
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --propose-recognizers "${extra[@]}" --json < /dev/null) )
  rust_out=$(   "$RUST_BIN" --corpus "$rust_path" --propose-recognizers "${extra[@]}" --json < /dev/null )
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
# Non-default thresholds must flow through identically: looser floors keep
# the proposal; a min-hosts floor above the corpus (single host) drops it.
propose_pair "JSON + loose thresholds" ".json" --min-observations 10 --min-coverage 0.5 --min-hosts 1
propose_pair "SQLite + min-hosts filter" ".db" --min-hosts 2
# Nothing clears --activate-above: the message names confidence, the threshold
# that filtered.
propose_pair "JSON + activate-above above every confidence" ".json" --activate-above 1.5

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
# return :ghp in both (Rust interns it as a dynamic Custom type). We use
# --activate-above to drive the activation through the CLI, assert the
# "activated:" lines match, then re-open each corpus and assert the
# activated recognizer survives persistence: normalizing a fresh
# PAT-shaped URL through the corpus must render the {ghp} placeholder
# identically in both runtimes.
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
  if [[ "$ruby_out" != "$rust_out" ]]; then
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: activate-above $label"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
    return
  fi
  # Reopen: the activated recognizer must be re-applied from storage and
  # drive normalize output ({ghp} placeholder) identically.
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" -n "https://api.github.com/auth/ghp_zzzz9999xyzzy") )
  rust_out=$(   "$RUST_BIN" --corpus "$rust_path" -n "https://api.github.com/auth/ghp_zzzz9999xyzzy" )
  if [[ "$ruby_out" == "$rust_out" ]] && echo "$ruby_out" | grep -q '{ghp}'; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: activate-above reopen $label"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
    echo "$ruby_out" | grep -q '{ghp}' || echo "    (ruby output lacks {ghp} placeholder)"
  fi
}

activate_pair "JSON storage"   ".json"
activate_pair "SQLite storage" ".db"

# A proposal never takes a built-in type name: `literal_` proposes
# `literal_id`, and activating it classifies new values as {literal_id}.
reserved_name_side() {
  local path="$1"
  shift
  rm -f "$path" "$path-wal" "$path-shm"
  local stream=""
  for i in $(seq 10 34); do stream+="https://api.x.com/t/literal_Zz$i"$'\n'; done
  echo -n "$stream" | "$@" --corpus "$path" > /dev/null 2>&1
  "$@" --corpus "$path" --propose-recognizers --json < /dev/null
  "$@" --corpus "$path" --propose-recognizers --activate-above 0.9 < /dev/null
  "$@" --corpus "$path" -n "https://api.x.com/t/literal_Zz99" < /dev/null
}
ruby_reserved=$(cd "$REPO_ROOT" && reserved_name_side "$corpus_dir/ruby-reserved.db" $RUBY 2>&1)
rust_reserved=$(reserved_name_side "$corpus_dir/rust-reserved.db" "$RUST_BIN" 2>&1)
if [[ "$ruby_reserved" == "$rust_reserved" ]] && [[ "$ruby_reserved" == *'{literal_id}'* ]]; then
  pass_count=$((pass_count + 1))
else
  fail_count=$((fail_count + 1))
  echo; echo "MISMATCH: proposal named after a built-in type gets _id"
  diff <(echo "$ruby_reserved") <(echo "$rust_reserved") | sed 's/^/    /' || true
fi

# --cross-host-shapes parity. Stream IRIs across multiple hosts that
# share the same shape; both runtimes should report identical output.
cross_host_pair() {
  local label="$1" ext="$2"
  shift 2
  local extra=("$@")
  local ruby_path="$corpus_dir/ruby-xh$ext"
  local rust_path="$corpus_dir/rust-xh$ext"
  rm -f "$ruby_path" "$rust_path"
  local xh_stream=$'https://foo.com/users/1\nhttps://bar.com/users/2\nhttps://baz.com/users/3\nhttps://foo.com/posts/abc\nhttps://bar.com/posts/def\n'
  echo -n "$xh_stream" | (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path") > /dev/null
  echo -n "$xh_stream" | "$RUST_BIN" --corpus "$rust_path" > /dev/null
  local ruby_out rust_out
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --cross-host-shapes "${extra[@]}" < /dev/null) )
  rust_out=$(   "$RUST_BIN" --corpus "$rust_path" --cross-host-shapes "${extra[@]}" < /dev/null )
  if [[ "$ruby_out" != "$rust_out" ]]; then
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: cross-host-shapes $label (human)"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
    return
  fi
  ruby_out=$( (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --cross-host-shapes "${extra[@]}" --json < /dev/null) )
  rust_out=$(   "$RUST_BIN" --corpus "$rust_path" --cross-host-shapes "${extra[@]}" --json < /dev/null )
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
# --min-hosts above the default (2): /users/{id} spans 3 hosts and stays;
# /posts/{x} spans only 2 and drops out.
cross_host_pair "JSON min-hosts=3" ".json" --min-hosts 3

# --host MODE should key clusters identically in both runtimes: full keeps
# subdomains, reg / registrable collapse to the apex, none ignores host.
host_strategy_pair() {
  local label="$1" mode="$2"
  local rstream=$'https://api.foo.com/users/1\nhttps://app.foo.com/users/2\nhttps://blog.example.co.uk/posts/3\nhttps://news.example.co.uk/posts/4\n'
  local ruby_path="$corpus_dir/ruby-host-$mode.json"
  local rust_path="$corpus_dir/rust-host-$mode.json"
  rm -f "$ruby_path" "$rust_path"
  echo -n "$rstream" | (cd "$REPO_ROOT" && $RUBY --corpus "$ruby_path" --host="$mode") > /dev/null
  echo -n "$rstream" | "$RUST_BIN" --corpus "$rust_path" --host="$mode" > /dev/null
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
host_strategy_pair "--host=reg collapses subdomains"         reg
host_strategy_pair "--host=registrable collapses subdomains" registrable
host_strategy_pair "--host=full keeps subdomains"            full
host_strategy_pair "--host=none ignores host"                none
# --host applies to the throwaway -C corpus too (it used to be ignored there).
run_pair "--host reg with -C" $'https://api.foo.com/users/1\nhttps://app.foo.com/users/2\n' -C --host reg cluster

# Default-corpus resolution via IRIQ_CORPUS. The harness globally exports
# IRIQ_NO_CORPUS=1; these scenarios undo it per invocation and point
# IRIQ_CORPUS at a tempfile, so the real default corpus path is never
# touched. First run on a fresh path prints the "created corpus at ..."
# stderr notice; a second run on the existing file must not.
env_corpus_pair() {
  local label="$1" fresh="$2"
  local path="$corpus_dir/env-default.db"
  local input="https://foo.com/users/1"
  local ruby_out rust_out
  if [[ "$fresh" == "fresh" ]]; then
    rm -f "$path" "$path-wal" "$path-shm" "$path.tmp"
  fi
  ruby_out=$(echo -n "$input" | (cd "$REPO_ROOT" && env -u IRIQ_NO_CORPUS IRIQ_CORPUS="$path" $RUBY -n) 2>&1 || true)
  if [[ "$fresh" == "fresh" ]]; then
    rm -f "$path" "$path-wal" "$path-shm" "$path.tmp"
  fi
  rust_out=$(echo -n "$input" | env -u IRIQ_NO_CORPUS IRIQ_CORPUS="$path" "$RUST_BIN" -n 2>&1 || true)
  if [[ "$ruby_out" == "$rust_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: $label"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
  fi
}
env_corpus_pair "IRIQ_CORPUS first run announces creation" fresh
env_corpus_pair "IRIQ_CORPUS second run is quiet"          existing

# Seeded messy-corpus sweep. The curated scenarios above use hand-picked
# inputs; this one pipes ~300 lines of deterministically corrupted URLs
# (fixed seed — the file is byte-identical on every run) through both
# binaries under several flag combos. Extends parity coverage from curated
# cases to bulk semi-random/hostile input.
messy_file="$corpus_dir/messy.txt"
(cd "$REPO_ROOT" && bundle exec ruby -r./spec/support/iri_generator -e '
  rng = Random.new(4242)
  inj = [" ", "{", "}", "|", "%00", "%zz", "%25", " ", "　",
         "”", "é", "例", "\u{1F980}", "\t", "..", "//",
         "?", "#", ":", "@"]
  IriGenerator.urls(count: 150, seed: 4242).each do |url|
    m = url.dup
    rng.rand(1..2).times do
      case rng.rand(5)
      when 0 then m = m[0, rng.rand(1..m.length)]                              # truncate
      when 1 then p = rng.rand(m.length + 1)
                  m = m[0, p] + inj.sample(random: rng) + m[p..]               # inject
      when 2 then m = m.gsub("%", "%25")                                      # double-encode
      when 3 then m = inj.sample(random: rng) + m                             # prepend
      else        m += inj.sample(random: rng)                                # append
      end
    end
    puts url
    puts m
  end
') > "$messy_file"

# jq=1 compares through `jq -S` (same convention as run_pair_json): the
# cluster views' per-segment values maps have runtime-specific key order.
messy_pair() {
  local jq_mode="$1" label="$2"
  shift 2
  if [[ "$jq_mode" == "1" ]] && ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  local ruby_out rust_out
  if [[ "$jq_mode" == "1" ]]; then
    local norm='walk(if type == "number" then . + 0 else . end)'
    ruby_out=$( (cd "$REPO_ROOT" && $RUBY "$@" < "$messy_file") 2>&1 | jq -S "$norm" 2>&1 || true )
    rust_out=$( "$RUST_BIN" "$@" < "$messy_file" 2>&1 | jq -S "$norm" 2>&1 || true )
  else
    ruby_out=$( (cd "$REPO_ROOT" && $RUBY "$@" < "$messy_file") 2>&1 || true )
    rust_out=$( "$RUST_BIN" "$@" < "$messy_file" 2>&1 || true )
  fi
  if [[ "$ruby_out" == "$rust_out" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo
    echo "MISMATCH: messy corpus $label"
    diff <(echo "$ruby_out") <(echo "$rust_out") | sed 's/^/    /' || true
  fi
}

messy_pair 0 "url list (summary)"
messy_pair 0 "-n"           -n
messy_pair 0 "-pcn --json"  -pcn --json
messy_pair 1 "--ndjson"     --ndjson

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
if [[ $fail_count -gt 0 ]]; then
  exit 1
fi
