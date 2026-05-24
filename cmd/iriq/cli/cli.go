// Package cli implements the `iriq` command in Go. Mirrors lib/iriq/cli.rb.
package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/dpep/iriq"
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

Corpus + stats:
      --corpus PATH     Load/create a JSON corpus; observe and save atomically.
                        -n becomes corpus-informed once it has data.
      --stats           Print rolling aggregates

Other:
  -h, --help            Show this message
  -j, --json            Emit JSON instead of human-readable output
  -N, --no-hints        Use {integer_id} placeholders instead of {user_id}
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

type section int

const (
	sectionParse section = iota
	sectionNormalize
)

type options struct {
	help       bool
	version    bool
	json       bool
	hints      bool
	sections   []section
	corpus     string
	stats      bool
	schemeLess bool
}

func defaultOptions() *options {
	return &options{hints: true, schemeLess: true}
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
		return 0
	}
	if opts.version {
		fmt.Fprintln(stdout, iriq.Version)
		return 0
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

	if len(args) == 0 && !batchMode {
		fmt.Fprint(stdout, usage)
		return 0
	}

	var corpus *iriq.Corpus
	if opts.corpus != "" {
		c, err := loadCorpus(opts.corpus)
		if err != nil {
			fmt.Fprintf(stderr, "iriq: %s\n", err)
			return 1
		}
		corpus = c
	}

	var code int
	switch {
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
	return code
}

func parseableIRI(input string) bool {
	_, err := iriq.Parse(input)
	return err == nil
}

func loadCorpus(path string) (*iriq.Corpus, error) {
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		return iriq.NewCorpus(), nil
	} else if err != nil {
		return nil, err
	}
	return iriq.LoadCorpus(path)
}

func pipedStdin(stdin io.Reader) bool {
	if f, ok := stdin.(*os.File); ok {
		info, err := f.Stat()
		if err != nil {
			return true
		}
		return (info.Mode() & os.ModeCharDevice) == 0
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
		case a == "--stats":
			opts.stats = true
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
		case a == "--corpus":
			if i+1 >= len(argv) {
				return nil, nil, fmt.Errorf("missing argument: --corpus PATH")
			}
			opts.corpus = argv[i+1]
			i++
		case strings.HasPrefix(a, "--corpus="):
			opts.corpus = strings.TrimPrefix(a, "--corpus=")
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
				case 'j':
					opts.json = true
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
	for _, iri := range iris {
		_, _ = corpus.Observe(iri)
	}

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
// path_segments, query_params, fragment, nss, canonical).
func identifierMap(iri *iriq.Identifier) *identifierJSON {
	out := &identifierJSON{
		Original:     iri.Original,
		Kind:         iri.Kind.String(),
		PathSegments: iri.PathSegments,
		QueryParams:  iri.QueryParams.ToMap(),
		Canonical:    iri.Canonical(),
	}
	if out.PathSegments == nil {
		out.PathSegments = []string{}
	}
	if out.QueryParams == nil {
		out.QueryParams = map[string]string{}
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

// identifierJSON exists purely to pin the JSON field order to Ruby's. The
// nullable string/int fields are pointers so json.Marshal emits `null` for
// absent values rather than the zero string.
type identifierJSON struct {
	Original     string            `json:"original"`
	Kind         string            `json:"kind"`
	Scheme       *string           `json:"scheme"`
	Host         *string           `json:"host"`
	Port         *int              `json:"port"`
	PathSegments []string          `json:"path_segments"`
	QueryParams  map[string]string `json:"query_params"`
	Fragment     *string           `json:"fragment"`
	NSS          *string           `json:"nss"`
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
		}
	}
}

func sectionName(s section) string {
	if s == sectionParse {
		return "parse"
	}
	return "normalize"
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
	if h["kind"] == "url" {
		segs := h["path_segments"].([]string)
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
			writeJSON(stdout, flat)
		} else {
			writeJSON(stdout, payloads)
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
		out := make([]map[string]interface{}, len(order))
		for i, c := range order {
			out[i] = map[string]interface{}{"iri": c.URL, "count": c.Count}
		}
		writeJSON(stdout, out)
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
			out[i] = map[string]interface{}{
				"key":      c.Key,
				"host":     c.Host,
				"scheme":   c.Scheme,
				"shape":    c.Shape,
				"count":    c.Count,
				"examples": examples,
				"segments": segs,
			}
		}
		writeJSON(stdout, out)
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
		if c.Count > 3 {
			fmt.Fprintf(stdout, "    + %d more\n", c.Count-3)
		}
	}
}

func rawShapeFor(c *iriq.Cluster) string {
	if len(c.Examples) == 0 {
		return c.Shape
	}
	return iriq.PathShapeFor(c.Examples[0].PathSegments, false)
}

func emitStats(stdout io.Writer, corpus *iriq.Corpus, opts *options) {
	observations := 0
	for _, v := range corpus.HostCounts {
		observations += v
	}
	hosts := topNMap(corpus.HostCounts, topNStats)
	shapes := topNMap(corpus.FingerprintCounts, topNStats)
	raw := topNMap(corpus.RawShapeCounts, topNStats)

	if opts.json {
		payload := map[string]interface{}{
			"observations": observations,
			"clusters":     corpus.Size(),
			"hosts":        mapFromPairs(hosts),
			"shapes":       mapFromPairs(shapes),
			"raw_shapes":   mapFromPairs(raw),
		}
		writeJSON(stdout, payload)
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

func parseMsg(err error) string {
	if pe, ok := err.(*iriq.ParseError); ok {
		return pe.Msg
	}
	return err.Error()
}
