package iriq

import (
	"regexp"
	"strings"
)

// Heuristic registrable-domain extractor — strips subdomains so api.foo.com
// and app.foo.com both resolve to foo.com.
//
// Uses an inline allowlist of the ~70 most common multi-label public
// suffixes (.co.uk, .com.au, .gov.uk, etc.). Covers the long tail of
// real-world traffic without bundling the full Public Suffix List
// (~3 MB into the Go binary). Niche multi-label TLDs (.priv.no,
// .tas.gov.au, etc.) will be over-stripped — users that hit those can
// pre-process their host before observing.

var twoLabelSuffixes = map[string]struct{}{
	"co.uk": {}, "org.uk": {}, "gov.uk": {}, "ac.uk": {}, "net.uk": {}, "me.uk": {}, "ltd.uk": {}, "plc.uk": {}, "sch.uk": {},
	"co.jp": {}, "ac.jp": {}, "or.jp": {}, "ne.jp": {}, "go.jp": {}, "gr.jp": {}, "ed.jp": {}, "lg.jp": {},
	"com.au": {}, "net.au": {}, "org.au": {}, "edu.au": {}, "gov.au": {}, "asn.au": {}, "id.au": {},
	"co.nz": {}, "net.nz": {}, "org.nz": {}, "govt.nz": {}, "ac.nz": {}, "school.nz": {},
	"com.br": {}, "net.br": {}, "org.br": {}, "gov.br": {}, "edu.br": {},
	"com.cn": {}, "net.cn": {}, "org.cn": {}, "gov.cn": {}, "edu.cn": {}, "ac.cn": {},
	"co.za": {}, "net.za": {}, "org.za": {}, "gov.za": {}, "ac.za": {},
	"co.kr": {}, "ne.kr": {}, "or.kr": {}, "re.kr": {}, "go.kr": {}, "ac.kr": {},
	"co.in": {}, "net.in": {}, "org.in": {}, "gov.in": {}, "ac.in": {},
	"co.il": {}, "net.il": {}, "org.il": {}, "gov.il": {}, "ac.il": {}, "muni.il": {},
	"com.mx": {}, "net.mx": {}, "org.mx": {}, "gob.mx": {}, "edu.mx": {},
	"com.ar": {}, "net.ar": {}, "org.ar": {}, "gov.ar": {},
	"com.hk": {}, "net.hk": {}, "org.hk": {}, "gov.hk": {}, "edu.hk": {},
	"com.tw": {}, "net.tw": {}, "org.tw": {}, "gov.tw": {}, "edu.tw": {},
	"com.sg": {}, "net.sg": {}, "org.sg": {}, "gov.sg": {}, "edu.sg": {}, "per.sg": {},
	"com.tr": {}, "net.tr": {}, "org.tr": {}, "gov.tr": {}, "edu.tr": {}, "k12.tr": {},
}

var ipv4RE = regexp.MustCompile(`^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$`)

// RegistrableDomain returns the registrable apex for a hostname (port not
// included). Returns the input unchanged for IPv4 literals, single-label
// hosts, and hosts already at 2-label apex form.
func RegistrableDomain(host string) string {
	if host == "" || ipv4RE.MatchString(host) {
		return host
	}
	labels := strings.Split(host, ".")
	if len(labels) <= 2 {
		return host
	}
	tail2 := labels[len(labels)-2] + "." + labels[len(labels)-1]
	if _, ok := twoLabelSuffixes[tail2]; ok {
		return strings.Join(labels[len(labels)-3:], ".")
	}
	return strings.Join(labels[len(labels)-2:], ".")
}
