package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dpep/iriq"
)

// stringReader satisfies emptyReporter so the CLI's pipedStdin check works
// without needing a real fd.
type stringReader struct {
	*strings.Reader
	empty bool
}

func (r *stringReader) IsEmpty() bool { return r.empty }

func newStdin(s string) io.Reader {
	return &stringReader{Reader: strings.NewReader(s), empty: s == ""}
}

type runResult struct {
	code   int
	stdout string
	stderr string
}

func runCLI(t *testing.T, stdin string, argv ...string) runResult {
	t.Helper()
	var out, errOut bytes.Buffer
	code := Run(newStdin(stdin), &out, &errOut, argv)
	return runResult{code, out.String(), errOut.String()}
}

func TestHelp(t *testing.T) {
	r := runCLI(t, "")
	if r.code != 0 {
		t.Errorf("code = %d", r.code)
	}
	if !strings.Contains(r.stdout, "Usage: iriq") {
		t.Errorf("missing usage: %q", r.stdout)
	}
}

func TestVersion(t *testing.T) {
	r := runCLI(t, "", "--version")
	if r.code != 0 || strings.TrimSpace(r.stdout) != iriq.Version {
		t.Errorf("got code=%d stdout=%q", r.code, r.stdout)
	}
}

func TestParseError(t *testing.T) {
	r := runCLI(t, "", "just-some-token")
	if r.code != 2 {
		t.Errorf("code = %d", r.code)
	}
	if !strings.Contains(r.stderr, "parse error") {
		t.Errorf("stderr = %q", r.stderr)
	}
}

func TestUnknownOption(t *testing.T) {
	r := runCLI(t, "", "--frobnicate")
	if r.code != 1 {
		t.Errorf("code = %d", r.code)
	}
}

// errorCode parses the structured stderr envelope and returns its code.
func errorCode(t *testing.T, stderr string) string {
	t.Helper()
	var env struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(stderr), &env); err != nil {
		t.Fatalf("stderr is not a JSON error envelope: %q (%v)", stderr, err)
	}
	return env.Error.Code
}

func TestJSONErrorEnvelope(t *testing.T) {
	cases := []struct {
		name string
		code int
		want string
		argv []string
	}{
		{"parse", 2, "parse_error", []string{"--json", "just-some-token"}},
		{"option", 1, "option_error", []string{"--json", "--frobnicate"}},
		{"missing", 1, "missing_argument", []string{"--propose-recognizers", "--json"}},
		{"shell", 1, "unknown_shell", []string{"completion", "fish", "--json"}},
		{"bundled-J", 2, "parse_error", []string{"-nJ", "just-some-token"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := runCLI(t, "", tc.argv...)
			if r.code != tc.code {
				t.Errorf("code = %d, want %d", r.code, tc.code)
			}
			if r.stdout != "" {
				t.Errorf("stdout should be empty, got %q", r.stdout)
			}
			if got := errorCode(t, r.stderr); got != tc.want {
				t.Errorf("error code = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestPlainErrorWithoutJSON(t *testing.T) {
	r := runCLI(t, "", "just-some-token")
	if !strings.HasPrefix(r.stderr, "iriq: parse error:") {
		t.Errorf("stderr = %q", r.stderr)
	}
}

func TestDefaultParseAndNormalize(t *testing.T) {
	r := runCLI(t, "", "foo.com/users/123")
	if r.code != 0 {
		t.Fatalf("code = %d: %s", r.code, r.stderr)
	}
	for _, want := range []string{
		"# parse", "scheme:        https", "host:          foo.com",
		"# normalize", "https://foo.com/users/{user_id}",
	} {
		if !strings.Contains(r.stdout, want) {
			t.Errorf("missing %q in %q", want, r.stdout)
		}
	}
}

func TestJSONSingleSection(t *testing.T) {
	r := runCLI(t, "", "-n", "--json", "foo.com/users/123")
	if r.code != 0 {
		t.Fatalf("code = %d", r.code)
	}
	var v interface{}
	if err := json.Unmarshal([]byte(r.stdout), &v); err != nil {
		t.Fatalf("json: %v", err)
	}
	if v != "https://foo.com/users/{user_id}" {
		t.Errorf("got %v", v)
	}
}

func TestJSONMultiSection(t *testing.T) {
	r := runCLI(t, "", "-pn", "--json", "foo.com/users/123")
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(r.stdout), &m); err != nil {
		t.Fatalf("json: %v", err)
	}
	if _, ok := m["parse"]; !ok {
		t.Error("missing parse")
	}
	if m["normalize"] != "https://foo.com/users/{user_id}" {
		t.Errorf("got %v", m["normalize"])
	}
}

// TestMultiSectionJSONKeyOrder guards Ruby↔Go parity: multi-section JSON keys
// must emit in the fixed order parse, canonical, normalize — independent of
// the flag order — rather than Go's default alphabetical map ordering.
func TestMultiSectionJSONKeyOrder(t *testing.T) {
	for _, flags := range []string{"-pcn", "-ncp", "-pnc"} {
		r := runCLI(t, "", flags, "--json", "foo.com/users/1?a=1&b=2")
		pi := strings.Index(r.stdout, `"parse"`)
		ci := strings.Index(r.stdout, `"canonical":`)
		ni := strings.Index(r.stdout, `"normalize":`)
		if pi < 0 || ci < 0 || ni < 0 || !(pi < ci && ci < ni) {
			t.Errorf("%s: keys not in parse<canonical<normalize order: %s", flags, r.stdout)
		}
		// & must stay literal (no HTML escaping), matching Ruby's JSON.generate.
		if strings.Contains(r.stdout, "\\u0026") {
			t.Errorf("%s: ampersand was HTML-escaped: %s", flags, r.stdout)
		}
	}
}

func TestNoHints(t *testing.T) {
	r := runCLI(t, "", "-n", "--no-hints", "foo.com/users/123")
	if strings.TrimSpace(r.stdout) != "https://foo.com/users/{integer}" {
		t.Errorf("got %q", r.stdout)
	}
}

func TestCanonicalSection(t *testing.T) {
	// -c returns the canonical IRI with no shape normalization: scheme/host
	// are canonicalized (case, default port) but path values are preserved.
	r := runCLI(t, "", "-c", "HTTP://Foo.COM:80/users/123")
	if strings.TrimSpace(r.stdout) != "http://foo.com/users/123" {
		t.Errorf("got %q", r.stdout)
	}
}

func TestCanonicalJSONSingleSection(t *testing.T) {
	r := runCLI(t, "", "-c", "--json", "foo.com/users/123")
	var v interface{}
	if err := json.Unmarshal([]byte(r.stdout), &v); err != nil {
		t.Fatalf("json: %v", err)
	}
	if v != "https://foo.com/users/123" {
		t.Errorf("got %v", v)
	}
}

func TestPipeCanonical(t *testing.T) {
	r := runCLI(t, "see https://foo.com/users/1 and (https://foo.com/users/2)", "-c")
	lines := strings.Split(strings.TrimSpace(r.stdout), "\n")
	want := []string{"https://foo.com/users/1", "https://foo.com/users/2"}
	if len(lines) != len(want) || lines[0] != want[0] || lines[1] != want[1] {
		t.Errorf("got %v", lines)
	}
}

func TestPipeURLList(t *testing.T) {
	stdin := "https://foo.com/users/1\nhttps://foo.com/users/2\nhttps://foo.com/posts/abc-123/edit\n"
	r := runCLI(t, stdin)
	for _, want := range []string{"https://foo.com/users/1", "https://foo.com/users/2", "https://foo.com/posts/abc-123/edit"} {
		if !strings.Contains(r.stdout, want) {
			t.Errorf("missing %q", want)
		}
	}
	if strings.Contains(r.stdout, "[1]") {
		t.Errorf("shouldn't have [1] prefix when all unique")
	}
}

func TestPipeCountsWhenDuplicates(t *testing.T) {
	stdin := "https://foo.com\nhttps://foo.com\nhttps://bar.com\n"
	r := runCLI(t, stdin)
	want := "[2] https://foo.com\n[1] https://bar.com\n"
	if r.stdout != want {
		t.Errorf("got %q want %q", r.stdout, want)
	}
}

func TestPipeAutoCluster(t *testing.T) {
	var stdin strings.Builder
	for i := 1; i <= 10; i++ {
		stdin.WriteString("https://foo.com/users/")
		stdin.WriteString(itoaTest(i))
		stdin.WriteByte('\n')
	}
	r := runCLI(t, stdin.String())
	if !strings.Contains(r.stdout, "[10] foo.com  /users/{user_id}") {
		t.Errorf("missing cluster line: %q", r.stdout)
	}
}

func TestPipeStatsJSON(t *testing.T) {
	r := runCLI(t, "https://foo.com/users/1\n", "--stats", "--json")
	var v map[string]interface{}
	if err := json.Unmarshal([]byte(r.stdout), &v); err != nil {
		t.Fatalf("json: %v", err)
	}
	if int(v["observations"].(float64)) != 1 {
		t.Errorf("observations = %v", v["observations"])
	}
}

func TestPipeNormalize(t *testing.T) {
	r := runCLI(t, "see https://foo.com/users/1 and (https://foo.com/users/2)", "-n")
	lines := strings.Split(strings.TrimSpace(r.stdout), "\n")
	want := []string{"https://foo.com/users/{user_id}", "https://foo.com/users/{user_id}"}
	if len(lines) != len(want) || lines[0] != want[0] || lines[1] != want[1] {
		t.Errorf("got %v", lines)
	}
}

func TestClusterSubcommand(t *testing.T) {
	r := runCLI(t, "https://foo.com/users/1\nhttps://foo.com/users/2\n", "cluster")
	if !strings.Contains(r.stdout, "[2] foo.com  /users/{user_id}") {
		t.Errorf("got %q", r.stdout)
	}
}

func TestFileAutoDetect(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "input.log")
	if err := os.WriteFile(p, []byte("see https://foo.com.\nalso (https://bar.com).\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := runCLI(t, "", p)
	if !strings.Contains(r.stdout, "https://foo.com") || !strings.Contains(r.stdout, "https://bar.com") {
		t.Errorf("got %q", r.stdout)
	}
}

func TestCorpusPersistence(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "c.json")
	r := runCLI(t, "", "--corpus", p, "https://foo.com/users/1")
	if r.code != 0 {
		t.Fatalf("code = %d: %s", r.code, r.stderr)
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("corpus file: %v", err)
	}
	// Second invocation accumulates.
	r2 := runCLI(t, "", "--corpus", p, "https://foo.com/users/2")
	if r2.code != 0 {
		t.Fatalf("code = %d: %s", r2.code, r2.stderr)
	}
	data, _ := os.ReadFile(p)
	var v map[string]interface{}
	_ = json.Unmarshal(data, &v)
	hc := v["host_counts"].(map[string]interface{})
	if int(hc["foo.com"].(float64)) != 2 {
		t.Errorf("foo.com count = %v", hc["foo.com"])
	}
}

func TestCorpusInformedNormalize(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "c.json")
	for _, n := range []string{"alice", "bob", "carol", "dave", "erin", "frank", "gina", "hank", "ivan", "jane"} {
		r := runCLI(t, "", "--corpus", p, "https://foo.com/users/"+n+"/profile")
		if r.code != 0 {
			t.Fatalf("seed %s: %s", n, r.stderr)
		}
	}
	r := runCLI(t, "", "-n", "--corpus", p, "https://foo.com/users/zoe/profile")
	if r.code != 0 {
		t.Fatalf("code = %d: %s", r.code, r.stderr)
	}
	if strings.TrimSpace(r.stdout) != "https://foo.com/users/{user}/profile" {
		t.Errorf("got %q", r.stdout)
	}
}

// itoaTest is a tiny helper so we don't pull in strconv just for the test.
func itoaTest(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
