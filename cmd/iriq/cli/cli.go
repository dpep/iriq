// Package cli implements the `iriq` command in Go. Mirrors lib/iriq/cli.rb.
package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"reflect"
	"sort"
	"strconv"
	"strings"

	"github.com/dpep/iriq"
	"golang.org/x/term"
)

const (
	largeBatchThreshold = 10
	topNStats           = 10
)

const usage = `Usage: iriq [options] <input>
       iriq [options] < text
       iriq cluster [options] [file]

<input> may be an IRI, a file path (extracted automatically), or piped
text via stdin.

Sections (combine freely):
  -n, --normalize       Shape-normalized form
  -p, --parse           Parsed fields
  -e, --explain         Annotated trace — per-segment notes about why
                        each placeholder / canonical value was chosen

Corpus + stats:
      --corpus PATH     Load/create a JSON corpus; observe and save atomically.
                        -n becomes corpus-informed once it has data.
      --host MODE       Host-keying strategy for clustering:
                        full (default), registrable (or reg) strips
                        subdomains, none ignores host entirely.
      --stats           Print rolling aggregates
      --reinfer         Replay the source-IRI log through the current
                        classifier + reducers; rebuilds materialized
                        views from scratch. Requires --corpus.
      --propose-recognizers
                        Scan observed values for shape patterns that
                        recur enough to suggest a new Recognizer.
                        Combine with --json for structured output.
                        Requires --corpus.
      --min-observations N  (proposal threshold; default 20)
      --min-coverage F  (proposal threshold; default 0.7)
      --min-hosts N     (proposal threshold; default 1)
      --activate-above F  Promote every proposal at or above coverage F
                        into a live Recognizer on the corpus, then
                        reinfer.

Other:
  -h, --help            Show this message
  -j, --json            Emit JSON instead of human-readable output
  -J, --ndjson          Newline-delimited JSON (one object per line). Implies --json.
  -N, --no-hints        Use {integer} placeholders instead of {user_id}
      --no-scheme-less  Skip foo.com/path extraction (explicit-scheme only)
  -V, --version         Print version

Subcommands:
  cluster [file]        Force cluster view (default for >=10 IRIs anyway)

Examples:
  iriq foo.com/users/456
  iriq -n https://foo.com/users/123
  iriq ./access.log                     # auto-detect file -> extract URLs
  cat README.md | iriq -n               # one normalized URL per line
  cat README.md | iriq --corpus c.json
`

// buildLabel summarizes which corpus backends are compiled in. Surfaces on
// --help so users can tell which build they have without having to trigger
// a "this build doesn't support .db files" error.
func buildLabel() string {
	if iriq.HasSqlite {
		return "sqlite (json + .db/.sqlite/.sqlite3 corpus support)"
	}
	return "slim (json corpus only — install iriq-sqlite or build with -tags sqlite for .db support)"
}

type section int

const (
	sectionParse section = iota
	sectionNormalize
	sectionExplain
)

type options struct {
	help       bool
	version    bool
	json         bool
	ndjson       bool
	hints        bool
	sections     []section
	corpus       string
	stats        bool
	reinfer      bool
	propose      bool
	proposeMinObs      int
	proposeMinCoverage float64
	proposeMinHosts    int
	activateAbove      float64 // 0 means disabled
	schemeLess   bool
	hostStrategy iriq.HostStrategy
}

func defaultOptions() *options {
	return &options{hints: true, schemeLess: true, hostStrategy: iriq.HostStrategyFull}
}

// Run executes the CLI and returns an exit code.
func Run(stdin io.Reader, stdout, stderr io.Writer, argv []string) int {
	args, opts, err := parseOptions(argv)
	if err != nil {
		fmt.Fprintf(stderr, "iriq: %s\n", err)
		return 1
	}
	if opts.help {
		fmt.Fprint(stdout, usage)
		fmt.Fprintf(stdout, "\nBuild: %s\n", buildLabel())
		return 0
	}
	if opts.version {
		fmt.Fprintln(stdout, iriq.Version)
		return 0
	}

	// `iriq completion <shell>` short-circuits — no corpus, no IRI input,
	// just emit the embedded script.
	if len(args) > 0 && args[0] == "completion" {
		return cmdCompletion(args[1:], stdout, stderr)
	}

	explicitCluster := false
	if len(args) > 0 && args[0] == "cluster" {
		explicitCluster = true
		args = args[1:]
	}

	positionalIsFile := false
	if len(args) > 0 {
		if info, statErr := os.Stat(args[0]); statErr == nil && !info.IsDir() && !parseableIRI(args[0]) {
			positionalIsFile = true
		}
	}

	batchMode := explicitCluster || positionalIsFile || (len(args) == 0 && pipedStdin(stdin))

	if len(args) == 0 && !batchMode && !opts.reinfer && !opts.propose {
		fmt.Fprint(stdout, usage)
		return 0
	}

	var corpus *iriq.Corpus
	if opts.corpus != "" {
		c, err := loadCorpus(opts.corpus, opts.hostStrategy)
		if err != nil {
			fmt.Fprintf(stderr, "iriq: %s\n", err)
			return 1
		}
		corpus = c
	}

	var code int
	switch {
	case opts.reinfer:
		code = cmdReinfer(stdout, stderr, corpus)
	case opts.propose:
		code = cmdPropose(stdout, stderr, corpus, opts)
	case batchMode:
		code = cmdBatch(stdin, stdout, stderr, args, opts, corpus, explicitCluster)
	case opts.stats:
		code = cmdStats(stdout, stderr, corpus, opts)
	default:
		code = cmdSummary(stdout, stderr, args, opts, corpus)
	}

	if corpus != nil && opts.corpus != "" {
		if err := corpus.Save(opts.corpus); err != nil {
			fmt.Fprintf(stderr, "iriq: %s\n", err)
			return 1
		}
	}
	if corpus != nil {
		_ = corpus.Close()
	}
	return code
}

func parseableIRI(input string) bool {
	_, err := iriq.Parse(input)
	return err == nil
}

func loadCorpus(path string, host iriq.HostStrategy) (*iriq.Corpus, error) {
	// OpenCorpus handles both create and load — picks the backend by file
	// extension and creates the file (with schema, for SQLite) if it doesn't
	// yet exist.
	c, err := iriq.OpenCorpus(path)
	if err != nil {
		return nil, err
	}
	c.HostStrategy = host
	return c, nil
}

// parseHostStrategy accepts full|registrable|reg|none (case-insensitive).
func parseHostStrategy(value string) (iriq.HostStrategy, error) {
	switch strings.ToLower(value) {
	case "full":
		return iriq.HostStrategyFull, nil
	case "registrable", "reg":
		return iriq.HostStrategyRegistrable, nil
	case "none":
		return iriq.HostStrategyNone, nil
	}
	return 0, fmt.Errorf("--host: expected full|registrable|reg|none, got %q", value)
}

func pipedStdin(stdin io.Reader) bool {
	if f, ok := stdin.(*os.File); ok {
		// True isatty check — pipe, regular file, and /dev/null all read as
		// "not a TTY" and should put the CLI in batch mode (matching Ruby's
		// !stdin.tty? behavior).
		return !term.IsTerminal(int(f.Fd()))
	}
	// Non-file readers (e.g. tests passing a bytes.Buffer with data) are
	// treated as piped only when they have data — best we can do without
	// peeking. Caller usually wraps in a NonEmptyReader if it matters.
	if er, ok := stdin.(emptyReporter); ok {
		return !er.IsEmpty()
	}
	return true
}

// emptyReporter is an optional interface tests can implement to indicate
// whether the reader has data. Mirrors the StringIO check in the Ruby CLI.
type emptyReporter interface{ IsEmpty() bool }

// parseOptions is a hand-rolled flag parser so we can preserve OptionParser's
// quirks: combined short flags (-pn), -N as a shorthand for --no-hints, etc.
func parseOptions(argv []string) ([]string, *options, error) {
	opts := defaultOptions()
	args := []string{}

	i := 0
	for i < len(argv) {
		a := argv[i]
		switch {
		case a == "--":
			args = append(args, argv[i+1:]...)
			return args, opts, nil
		case a == "-h" || a == "--help":
			opts.help = true
		case a == "-V" || a == "--version":
			opts.version = true
		case a == "-j" || a == "--json":
			opts.json = true
		case a == "-J" || a == "--ndjson":
			opts.json = true
			opts.ndjson = true
		case a == "--stats":
			opts.stats = true
		case a == "--reinfer":
			opts.reinfer = true
		case a == "--propose-recognizers":
			opts.propose = true
		case a == "--min-observations":
			if i+1 >= len(argv) {
				return nil, nil, fmt.Errorf("missing argument: --min-observations N")
			}
			n, err := strconv.Atoi(argv[i+1])
			if err != nil {
				return nil, nil, fmt.Errorf("--min-observations N: %w", err)
			}
			opts.proposeMinObs = n
			i++
		case a == "--min-coverage":
			if i+1 >= len(argv) {
				return nil, nil, fmt.Errorf("missing argument: --min-coverage F")
			}
			f, err := strconv.ParseFloat(argv[i+1], 64)
			if err != nil {
				return nil, nil, fmt.Errorf("--min-coverage F: %w", err)
			}
			opts.proposeMinCoverage = f
			i++
		case a == "--min-hosts":
			if i+1 >= len(argv) {
				return nil, nil, fmt.Errorf("missing argument: --min-hosts N")
			}
			n, err := strconv.Atoi(argv[i+1])
			if err != nil {
				return nil, nil, fmt.Errorf("--min-hosts N: %w", err)
			}
			opts.proposeMinHosts = n
			i++
		case a == "--activate-above":
			if i+1 >= len(argv) {
				return nil, nil, fmt.Errorf("missing argument: --activate-above F")
			}
			f, err := strconv.ParseFloat(argv[i+1], 64)
			if err != nil {
				return nil, nil, fmt.Errorf("--activate-above F: %w", err)
			}
			opts.activateAbove = f
			i++
		case a == "--hints":
			opts.hints = true
		case a == "--no-hints" || a == "-N":
			opts.hints = false
		case a == "--scheme-less":
			opts.schemeLess = true
		case a == "--no-scheme-less":
			opts.schemeLess = false
		case a == "-p" || a == "--parse":
			opts.sections = append(opts.sections, sectionParse)
		case a == "-n" || a == "--normalize":
			opts.sections = append(opts.sections, sectionNormalize)
		case a == "-e" || a == "--explain":
			opts.sections = append(opts.sections, sectionExplain)
		case a == "--corpus":
			if i+1 >= len(argv) {
				return nil, nil, fmt.Errorf("missing argument: --corpus PATH")
			}
			opts.corpus = argv[i+1]
			i++
		case strings.HasPrefix(a, "--corpus="):
			opts.corpus = strings.TrimPrefix(a, "--corpus=")
		case a == "--host":
			if i+1 >= len(argv) {
				return nil, nil, fmt.Errorf("missing argument: --host MODE")
			}
			s, err := parseHostStrategy(argv[i+1])
			if err != nil {
				return nil, nil, err
			}
			opts.hostStrategy = s
			i++
		case strings.HasPrefix(a, "--host="):
			s, err := parseHostStrategy(strings.TrimPrefix(a, "--host="))
			if err != nil {
				return nil, nil, err
			}
			opts.hostStrategy = s
		case strings.HasPrefix(a, "--"):
			return nil, nil, fmt.Errorf("invalid option: %s", a)
		case strings.HasPrefix(a, "-") && len(a) > 1:
			// Combined short flags like -pn or -nN.
			for _, ch := range a[1:] {
				switch ch {
				case 'p':
					opts.sections = append(opts.sections, sectionParse)
				case 'n':
					opts.sections = append(opts.sections, sectionNormalize)
				case 'e':
					opts.sections = append(opts.sections, sectionExplain)
				case 'j':
					opts.json = true
				case 'J':
					opts.json = true
					opts.ndjson = true
				case 'N':
					opts.hints = false
				case 'h':
					opts.help = true
				case 'V':
					opts.version = true
				default:
					return nil, nil, fmt.Errorf("invalid option: -%c", ch)
				}
			}
		default:
			args = append(args, a)
		}
		i++
	}
	return args, opts, nil
}

func cmdSummary(stdout, stderr io.Writer, args []string, opts *options, corpus *iriq.Corpus) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "iriq: missing argument <input>")
		return 1
	}
	iri, err := iriq.Parse(args[0])
	if err != nil {
		fmt.Fprintf(stderr, "iriq: parse error: %s\n", parseMsg(err))
		return 2
	}
	if corpus != nil {
		_, _ = corpus.Observe(iri)
	}
	sections := opts.sections
	if len(sections) == 0 {
		sections = []section{sectionParse, sectionNormalize}
	}

	data := map[string]interface{}{}
	for _, s := range sections {
		switch s {
		case sectionParse:
			data["parse"] = identifierMap(iri)
		case sectionNormalize:
			if corpus != nil {
				data["normalize"] = corpus.NormalizeIdentifier(iri)
			} else {
				data["normalize"] = iriq.NormalizeIdentifier(iri, nil, opts.hints)
			}
		case sectionExplain:
			data["explain"] = iriq.TraceIdentifier(iri, nil, opts.hints)
		}
	}

	if opts.json {
		var payload interface{} = data
		if len(sections) == 1 {
			for _, v := range data {
				payload = v
			}
		}
		writeJSON(stdout, payload)
	} else {
		emitSections(stdout, data, sections)
	}
	return 0
}

func cmdBatch(stdin io.Reader, stdout, stderr io.Writer, args []string, opts *options, corpus *iriq.Corpus, explicitCluster bool) int {
	if corpus == nil {
		corpus = iriq.NewCorpus()
	}
	text, err := readText(stdin, args)
	if err != nil {
		fmt.Fprintf(stderr, "iriq: %s\n", err)
		return 1
	}
	extractor := &iriq.Extractor{SchemeLess: opts.schemeLess}
	iris := extractor.Extract(text)
	_ = corpus.Batch(func() error {
		for _, iri := range iris {
			_, _ = corpus.Observe(iri)
		}
		return nil
	})

	switch {
	case len(opts.sections) > 0:
		emitPerIRISections(stdout, iris, opts)
	case opts.stats:
		emitStats(stdout, corpus, opts)
	case explicitCluster || len(iris) >= largeBatchThreshold:
		emitClusters(stdout, corpus.Clusters(), opts)
	default:
		emitURLList(stdout, iris, opts)
	}
	return 0
}

// formatFloatRubyStyle matches Ruby's JSON.generate output for floats:
// whole-number floats render with a trailing ".0" (1.0 → "1.0", not "1"),
// fractional floats use the shortest accurate representation. Used for
// coverage values where parity vs the Ruby CLI matters.
func formatFloatRubyStyle(f float64) string {
	s := strconv.FormatFloat(f, 'g', -1, 64)
	if !strings.ContainsAny(s, ".eE") {
		s += ".0"
	}
	return s
}

// cmdPropose scans observed values for prefix patterns that recur enough
// to suggest a new Recognizer. One block per proposal in human mode,
// JSON array under --json.
func cmdPropose(stdout, stderr io.Writer, corpus *iriq.Corpus, opts *options) int {
	if corpus == nil {
		fmt.Fprintln(stderr, "iriq: missing argument <--corpus>")
		return 1
	}

	popts := iriq.ProposalOptions{
		MinObservations: opts.proposeMinObs,
		MinCoverage:     opts.proposeMinCoverage,
		MinHosts:        opts.proposeMinHosts,
	}

	if opts.activateAbove > 0 {
		activated, err := corpus.ActivateProposalsAbove(opts.activateAbove, popts)
		if err != nil {
			fmt.Fprintf(stderr, "iriq: %s\n", err)
			return 1
		}
		if len(activated) == 0 {
			fmt.Fprintf(stdout, "no proposals at or above coverage %g\n", opts.activateAbove)
			return 0
		}
		for _, r := range activated {
			fmt.Fprintf(stdout, "activated: %s (%s)\n", r.Type, r.Prefix)
		}
		return 0
	}

	proposals := corpus.ProposeRecognizers(nil, popts)

	if opts.json {
		// Match Ruby's RecognizerProposal#to_h field order + numeric
		// formatting so JSON parity holds byte-for-byte.
		//   * Position fields ordered (host, scope, locator) via explicit
		//     struct tags; Go's encoder would alphabetize a map[string]any.
		//   * Coverage emitted as a json.RawMessage so we control the
		//     decimal representation: Ruby's JSON.generate keeps "1.0"
		//     for whole-number floats; Go's default would drop to "1".
		type positionJSON struct {
			Host    string `json:"host"`
			Scope   string `json:"scope"`
			Locator string `json:"locator"`
		}
		type proposalJSON struct {
			Prefix           string          `json:"prefix"`
			SuggestedType    string          `json:"suggested_type"`
			Positions        []positionJSON  `json:"positions"`
			Hosts            []string        `json:"hosts"`
			Coverage         json.RawMessage `json:"coverage"`
			ObservationCount int             `json:"observation_count"`
			SampleValues     []string        `json:"sample_values"`
			Strategy         string          `json:"strategy"`
		}
		out := make([]proposalJSON, 0, len(proposals))
		for _, p := range proposals {
			positions := make([]positionJSON, len(p.Positions))
			for i, pos := range p.Positions {
				positions[i] = positionJSON{
					Host: pos.Host, Scope: string(pos.Scope), Locator: pos.Locator,
				}
			}
			out = append(out, proposalJSON{
				Prefix:           p.Prefix,
				SuggestedType:    p.SuggestedType,
				Positions:        positions,
				Hosts:            p.Hosts,
				Coverage:         json.RawMessage(formatFloatRubyStyle(p.Coverage)),
				ObservationCount: p.ObservationCount,
				SampleValues:     p.SampleValues,
				Strategy:         p.Strategy,
			})
		}
		data, _ := json.Marshal(out)
		fmt.Fprintln(stdout, string(data))
		return 0
	}

	if len(proposals) == 0 {
		fmt.Fprintf(stdout, "no recognizer proposals (%d observations scanned)\n", corpus.ObservedIRICount())
		return 0
	}

	for i, p := range proposals {
		if i > 0 {
			fmt.Fprintln(stdout)
		}
		fmt.Fprintf(stdout, "proposal: %s (%s)\n", p.SuggestedType, p.Prefix)
		fmt.Fprintf(stdout, "  strategy:    %s\n", p.Strategy)
		fmt.Fprintf(stdout, "  coverage:    %.2f\n", p.Coverage)
		fmt.Fprintf(stdout, "  observations: %d\n", p.ObservationCount)
		fmt.Fprintf(stdout, "  hosts:       %s\n", strings.Join(p.Hosts, ", "))
		fmt.Fprintf(stdout, "  positions:   %d\n", len(p.Positions))
		samples := p.SampleValues
		if len(samples) > 3 {
			samples = samples[:3]
		}
		fmt.Fprintf(stdout, "  samples:     %s\n", strings.Join(samples, ", "))
	}
	return 0
}

// cmdReinfer drops the materialized views in the corpus and replays the
// source-IRI log through the current classifier + reducers. Prints a short
// before/after summary.
func cmdReinfer(stdout, stderr io.Writer, corpus *iriq.Corpus) int {
	if corpus == nil {
		fmt.Fprintln(stderr, "iriq: missing argument <--corpus>")
		return 1
	}
	n := corpus.ObservedIRICount()
	before := corpus.Size()
	if err := corpus.Reinfer(); err != nil {
		fmt.Fprintf(stderr, "iriq: %s\n", err)
		return 1
	}
	after := corpus.Size()
	noun := "observations"
	if n == 1 {
		noun = "observation"
	}
	clusters := "clusters"
	if after == 1 {
		clusters = "cluster"
	}
	fmt.Fprintf(stdout, "reinferred %d %s: %d → %d %s\n", n, noun, before, after, clusters)
	return 0
}

func cmdStats(stdout, stderr io.Writer, corpus *iriq.Corpus, opts *options) int {
	if corpus == nil {
		fmt.Fprintln(stderr, "iriq: missing argument <--corpus>")
		return 1
	}
	emitStats(stdout, corpus, opts)
	return 0
}

func readText(stdin io.Reader, args []string) (string, error) {
	if len(args) == 0 || args[0] == "-" {
		data, err := io.ReadAll(stdin)
		if err != nil {
			return "", err
		}
		return string(data), nil
	}
	data, err := os.ReadFile(args[0])
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// identifierMap returns a JSON-ready representation of an Identifier with key
// order matching the Ruby CLI (original, kind, scheme, host, port,
// path_segments, query_params, fragment, nss, canonical). Null/empty fields
// are dropped via `omitempty` on identifierJSON.
func identifierMap(iri *iriq.Identifier) *identifierJSON {
	out := &identifierJSON{
		Original:     iri.Original,
		Kind:         iri.Kind.String(),
		PathSegments: iri.PathSegments,
		QueryParams:  iri.QueryParams.ToMap(),
		Canonical:    iri.Canonical(),
	}
	if iri.Scheme != "" {
		s := iri.Scheme
		out.Scheme = &s
	}
	if iri.Host != "" {
		h := iri.Host
		out.Host = &h
	}
	if iri.Port != 0 {
		p := iri.Port
		out.Port = &p
	}
	if iri.Fragment != "" {
		f := iri.Fragment
		out.Fragment = &f
	}
	if iri.NSS != "" {
		n := iri.NSS
		out.NSS = &n
	}
	return out
}

// identifierJSON pins the JSON field order to Ruby's and drops null/empty
// values via omitempty so URN dumps don't carry empty host/path/query slots
// and URL dumps don't include null fragment/nss.
type identifierJSON struct {
	Original     string            `json:"original"`
	Kind         string            `json:"kind"`
	Scheme       *string           `json:"scheme,omitempty"`
	Host         *string           `json:"host,omitempty"`
	Port         *int              `json:"port,omitempty"`
	PathSegments []string          `json:"path_segments,omitempty"`
	QueryParams  map[string]string `json:"query_params,omitempty"`
	Fragment     *string           `json:"fragment,omitempty"`
	NSS          *string           `json:"nss,omitempty"`
	Canonical    string            `json:"canonical"`
}

func (j *identifierJSON) ParseHuman() map[string]interface{} {
	m := map[string]interface{}{
		"original":      j.Original,
		"kind":          j.Kind,
		"canonical":     j.Canonical,
		"path_segments": j.PathSegments,
		"query_params":  j.QueryParams,
	}
	if j.Scheme != nil {
		m["scheme"] = *j.Scheme
	}
	if j.Host != nil {
		m["host"] = *j.Host
	}
	if j.Port != nil {
		m["port"] = *j.Port
	}
	if j.Fragment != nil {
		m["fragment"] = *j.Fragment
	}
	if j.NSS != nil {
		m["nss"] = *j.NSS
	}
	return m
}

func emitSections(stdout io.Writer, data map[string]interface{}, sections []section) {
	multi := len(sections) > 1
	for i, s := range sections {
		if i > 0 {
			fmt.Fprintln(stdout)
		}
		if multi {
			fmt.Fprintf(stdout, "# %s\n", sectionName(s))
		}
		switch s {
		case sectionParse:
			emitParseHuman(stdout, data["parse"].(*identifierJSON).ParseHuman())
		case sectionNormalize:
			fmt.Fprintln(stdout, data["normalize"])
		case sectionExplain:
			emitExplainHuman(stdout, data["explain"].(*iriq.TraceResult))
		}
	}
}

func sectionName(s section) string {
	switch s {
	case sectionParse:
		return "parse"
	case sectionExplain:
		return "explain"
	}
	return "normalize"
}

func emitExplainHuman(stdout io.Writer, tr *iriq.TraceResult) {
	fmt.Fprintln(stdout, tr.Normalized)
	emitTraceSection(stdout, "path", tr.Path)
	if len(tr.Query) > 0 {
		emitTraceSection(stdout, "query", tr.Query)
	}
}

func emitTraceSection(stdout io.Writer, label string, rows []iriq.TraceRow) {
	if len(rows) == 0 {
		return
	}
	fmt.Fprintln(stdout)
	fmt.Fprintf(stdout, "%s:\n", label)
	nameWidth, typeWidth, outWidth := 0, 0, 0
	for _, r := range rows {
		l := traceRowLabel(r)
		if len(l) > nameWidth {
			nameWidth = len(l)
		}
		if len(r.Type) > typeWidth {
			typeWidth = len(string(r.Type))
		}
		if len(r.Output) > outWidth {
			outWidth = len(r.Output)
		}
	}
	for _, r := range rows {
		notes := ""
		if len(r.Notes) > 0 {
			notes = "  (" + strings.Join(r.Notes, "; ") + ")"
		}
		fmt.Fprintf(stdout, "  %-*s  %-*s  %-*s%s\n",
			nameWidth, traceRowLabel(r),
			typeWidth, r.Type,
			outWidth, r.Output,
			notes,
		)
	}
}

func traceRowLabel(r iriq.TraceRow) string {
	if r.Name != "" {
		return r.Name + "=" + r.Value
	}
	return r.Value
}

func emitParseHuman(stdout io.Writer, h map[string]interface{}) {
	fmt.Fprintf(stdout, "original:      %s\n", h["original"])
	fmt.Fprintf(stdout, "kind:          %s\n", h["kind"])
	if v := h["scheme"]; v != nil {
		fmt.Fprintf(stdout, "scheme:        %s\n", v)
	}
	if v := h["host"]; v != nil {
		fmt.Fprintf(stdout, "host:          %s\n", v)
	}
	if v := h["port"]; v != nil {
		fmt.Fprintf(stdout, "port:          %v\n", v)
	}
	if segs, ok := h["path_segments"].([]string); ok && len(segs) > 0 {
		fmt.Fprintf(stdout, "path_segments: %s\n", inspectStrings(segs))
	}
	if qp, ok := h["query_params"].(map[string]string); ok && len(qp) > 0 {
		fmt.Fprintf(stdout, "query_params:  %s\n", inspectStringMap(qp))
	}
	if v := h["fragment"]; v != nil {
		fmt.Fprintf(stdout, "fragment:      %s\n", v)
	}
	if v := h["nss"]; v != nil {
		fmt.Fprintf(stdout, "nss:           %s\n", v)
	}
	fmt.Fprintf(stdout, "canonical:     %s\n", h["canonical"])
}

func inspectStrings(ss []string) string {
	if len(ss) == 0 {
		return "[]"
	}
	parts := make([]string, len(ss))
	for i, s := range ss {
		parts[i] = strconv.Quote(s)
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

func inspectStringMap(m map[string]string) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = strconv.Quote(k) + "=>" + strconv.Quote(m[k])
	}
	return "{" + strings.Join(parts, ", ") + "}"
}

func emitPerIRISections(stdout io.Writer, iris []*iriq.Identifier, opts *options) {
	type payload map[string]interface{}
	payloads := make([]payload, len(iris))
	for i, iri := range iris {
		p := payload{}
		for _, s := range opts.sections {
			switch s {
			case sectionParse:
				p["parse"] = identifierMap(iri)
			case sectionNormalize:
				p["normalize"] = iriq.NormalizeIdentifier(iri, nil, opts.hints)
			}
		}
		payloads[i] = p
	}

	if opts.json {
		if len(opts.sections) == 1 {
			flat := make([]interface{}, 0, len(payloads))
			for _, p := range payloads {
				// Single section: emit just that value, matching Ruby
				// `payloads.map(&:values).flatten(1)`. There's only one
				// key per payload, so the loop iterates once.
				for _, s := range opts.sections {
					switch s {
					case sectionParse:
						flat = append(flat, p["parse"])
					case sectionNormalize:
						flat = append(flat, p["normalize"])
					}
				}
			}
			emitJSON(stdout, opts, flat)
		} else {
			emitJSON(stdout, opts, payloads)
		}
		return
	}

	if len(opts.sections) == 1 && opts.sections[0] == sectionNormalize {
		for _, p := range payloads {
			fmt.Fprintln(stdout, p["normalize"])
		}
		return
	}

	for i, p := range payloads {
		if i > 0 {
			fmt.Fprintln(stdout)
		}
		fmt.Fprintf(stdout, "# %s\n", iris[i].Canonical())
		for j, s := range opts.sections {
			if j > 0 {
				fmt.Fprintln(stdout)
			}
			switch s {
			case sectionParse:
				emitParseHuman(stdout, p["parse"].(*identifierJSON).ParseHuman())
			case sectionNormalize:
				fmt.Fprintln(stdout, p["normalize"])
			}
		}
	}
}

// urlCount tracks a URL's occurrence count and first-seen position.
type urlCount struct {
	URL   string
	Count int
	First int
}

func emitURLList(stdout io.Writer, iris []*iriq.Identifier, opts *options) {
	counts := map[string]*urlCount{}
	order := []*urlCount{}
	for i, iri := range iris {
		key := iri.Canonical()
		if c, ok := counts[key]; ok {
			c.Count++
		} else {
			c := &urlCount{URL: key, Count: 1, First: i}
			counts[key] = c
			order = append(order, c)
		}
	}
	sort.SliceStable(order, func(i, j int) bool {
		if order[i].Count != order[j].Count {
			return order[i].Count > order[j].Count
		}
		return order[i].First < order[j].First
	})

	if opts.json {
		// Struct (not map) to pin field order — Ruby emits {iri, count} in
		// insertion order; Go's map[string]interface{} sorts alphabetically.
		type urlCount struct {
			IRI   string `json:"iri"`
			Count int    `json:"count"`
		}
		out := make([]urlCount, len(order))
		for i, c := range order {
			out[i] = urlCount{IRI: c.URL, Count: c.Count}
		}
		emitJSON(stdout, opts, out)
		return
	}

	allUnique := true
	for _, c := range order {
		if c.Count != 1 {
			allUnique = false
			break
		}
	}
	for _, c := range order {
		if allUnique {
			fmt.Fprintln(stdout, c.URL)
		} else {
			fmt.Fprintf(stdout, "[%d] %s\n", c.Count, c.URL)
		}
	}
}

func emitClusters(stdout io.Writer, clusters []*iriq.Cluster, opts *options) {
	sorted := make([]*iriq.Cluster, len(clusters))
	copy(sorted, clusters)
	sort.SliceStable(sorted, func(i, j int) bool {
		return sorted[i].Count > sorted[j].Count
	})

	if opts.json {
		out := make([]map[string]interface{}, len(sorted))
		for i, c := range sorted {
			examples := make([]string, len(c.Examples))
			for j, e := range c.Examples {
				examples[j] = e.Canonical()
			}
			stats := c.SegmentStats()
			segs := make([]map[string]interface{}, len(stats))
			for j, s := range stats {
				segs[j] = map[string]interface{}{
					"position": s.Position,
					"stable":   s.Stable,
					"values":   s.Values,
				}
			}
			summaries := c.ParamSummary()
			params := make([]map[string]interface{}, len(summaries))
			for j, p := range summaries {
				params[j] = map[string]interface{}{
					"name":        p.Name,
					"count":       p.Count,
					"type":        string(p.Type),
					"cardinality": p.Cardinality,
					"presence":    p.Presence,
				}
			}
			out[i] = map[string]interface{}{
				"key":      c.Key,
				"host":     c.Host,
				"scheme":   c.Scheme,
				"shape":    c.Shape,
				"count":    c.Count,
				"examples": examples,
				"segments": segs,
				"params":   params,
			}
		}
		emitJSON(stdout, opts, out)
		return
	}

	for i, c := range sorted {
		if i > 0 {
			fmt.Fprintln(stdout)
		}
		host := c.Host
		if host == "" {
			host = "(urn)"
		}
		shape := c.Shape
		if !opts.hints {
			shape = rawShapeFor(c)
		}
		fmt.Fprintf(stdout, "[%d] %s  %s\n", c.Count, host, shape)
		limit := len(c.Examples)
		if limit > 3 {
			limit = 3
		}
		for j := 0; j < limit; j++ {
			fmt.Fprintf(stdout, "    %s\n", c.Examples[j].Canonical())
		}
		if remaining := c.Count - limit; remaining > 0 {
			fmt.Fprintf(stdout, "    + %d more\n", remaining)
		}
		emitParamSummary(stdout, c)
	}
}

// emitParamSummary renders one line per query param: type, numeric
// range (when present), cardinality, presence.
func emitParamSummary(stdout io.Writer, c *iriq.Cluster) {
	rows := c.ParamSummary()
	if len(rows) == 0 {
		return
	}
	width := 0
	for _, r := range rows {
		if len(r.Name) > width {
			width = len(r.Name)
		}
	}
	for _, r := range rows {
		parts := []string{string(r.Type)}
		if r.NumericCount > 0 {
			parts = append(parts, fmt.Sprintf("%s..%s", formatNum(r.Min), formatNum(r.Max)))
			parts = append(parts, fmt.Sprintf("avg %s", formatNum(r.Avg)))
		}
		parts = append(parts, fmt.Sprintf("(%d distinct, %d%%)", r.Cardinality, int(r.Presence*100+0.5)))
		fmt.Fprintf(stdout, "    %-*s  %s\n", width, r.Name, strings.Join(parts, "  "))
	}
}

// formatNum drops a trailing `.0` so `5.0` reads as `5`; rounds the
// rest to 2 decimal places.
func formatNum(n float64) string {
	whole := float64(int64(n))
	if whole == n {
		return fmt.Sprintf("%d", int64(n))
	}
	return strings.TrimRight(strings.TrimRight(fmt.Sprintf("%.2f", n), "0"), ".")
}

func rawShapeFor(c *iriq.Cluster) string {
	if len(c.Examples) == 0 {
		return c.Shape
	}
	return iriq.PathShapeFor(c.Examples[0].PathSegments, false)
}

func emitStats(stdout io.Writer, corpus *iriq.Corpus, opts *options) {
	hostCounts := corpus.HostCounts()
	observations := 0
	for _, v := range hostCounts {
		observations += v
	}
	hosts := topNMap(hostCounts, topNStats)
	shapes := topNMap(corpus.FingerprintCounts(), topNStats)
	raw := topNMap(corpus.RawShapeCounts(), topNStats)

	if opts.json {
		writeJSON(stdout, &statsJSON{
			Observations: observations,
			Clusters:     corpus.Size(),
			Hosts:        orderedKVList(hosts),
			Shapes:       orderedKVList(shapes),
			RawShapes:    orderedKVList(raw),
		})
		return
	}

	fmt.Fprintf(stdout, "observations: %d\n", observations)
	fmt.Fprintf(stdout, "clusters:     %d\n", corpus.Size())
	fmt.Fprintln(stdout)
	fmt.Fprintln(stdout, "top hosts:")
	for _, p := range hosts {
		fmt.Fprintf(stdout, "  %6d  %s\n", p.value, p.key)
	}
	fmt.Fprintln(stdout)
	fmt.Fprintln(stdout, "top shapes:")
	shapeRows := shapes
	if !opts.hints {
		shapeRows = raw
	}
	for _, p := range shapeRows {
		fmt.Fprintf(stdout, "  %6d  %s\n", p.value, p.key)
	}
}

type kv struct {
	key   string
	value int
}

// statsJSON pins JSON field order for --stats --json to match the Ruby
// implementation (Ruby Hash#to_json preserves insertion order; Go's
// map[string]interface{} sorts keys alphabetically).
type statsJSON struct {
	Observations int           `json:"observations"`
	Clusters     int           `json:"clusters"`
	Hosts        orderedKVList `json:"hosts"`
	Shapes       orderedKVList `json:"shapes"`
	RawShapes    orderedKVList `json:"raw_shapes"`
}

// orderedKVList is a sequence of (key, value) pairs that marshals as a JSON
// object preserving insertion order — Go's map[string]int sorts keys
// alphabetically, which breaks parity with Ruby's count-descending iteration.
type orderedKVList []kv

func (o orderedKVList) MarshalJSON() ([]byte, error) {
	var b strings.Builder
	b.WriteByte('{')
	for i, p := range o {
		if i > 0 {
			b.WriteByte(',')
		}
		kb, err := json.Marshal(p.key)
		if err != nil {
			return nil, err
		}
		b.Write(kb)
		b.WriteByte(':')
		vb, err := json.Marshal(p.value)
		if err != nil {
			return nil, err
		}
		b.Write(vb)
	}
	b.WriteByte('}')
	return []byte(b.String()), nil
}

func topNMap(m map[string]int, n int) []kv {
	pairs := make([]kv, 0, len(m))
	for k, v := range m {
		pairs = append(pairs, kv{k, v})
	}
	sort.Slice(pairs, func(i, j int) bool {
		if pairs[i].value != pairs[j].value {
			return pairs[i].value > pairs[j].value
		}
		return pairs[i].key < pairs[j].key
	})
	if len(pairs) > n {
		pairs = pairs[:n]
	}
	return pairs
}

func mapFromPairs(pairs []kv) map[string]int {
	out := make(map[string]int, len(pairs))
	for _, p := range pairs {
		out[p.key] = p.value
	}
	return out
}

func writeJSON(stdout io.Writer, v interface{}) {
	enc := json.NewEncoder(stdout)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
}

// emitJSON respects --ndjson: when the payload is a slice and ndjson is set,
// one JSON value is written per line (no wrapping array). Non-slice payloads
// fall through to the wrapping encoder unchanged. Mirrors emit_json in
// lib/iriq/cli.rb.
func emitJSON(stdout io.Writer, opts *options, payload interface{}) {
	if opts.ndjson {
		// Use reflection to handle any slice type ([]interface{}, []*Cluster, etc.).
		rv := reflectValue(payload)
		if rv.IsValid() && rv.Kind() == reflect.Slice {
			for i := 0; i < rv.Len(); i++ {
				writeJSON(stdout, rv.Index(i).Interface())
			}
			return
		}
	}
	writeJSON(stdout, payload)
}

func reflectValue(v interface{}) reflect.Value {
	return reflect.ValueOf(v)
}

func parseMsg(err error) string {
	if pe, ok := err.(*iriq.ParseError); ok {
		return pe.Msg
	}
	return err.Error()
}
