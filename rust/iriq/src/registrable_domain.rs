use once_cell::sync::Lazy;
use regex::Regex;
use std::collections::HashSet;

pub(crate) static IPV4_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$").unwrap());

static TWO_LABEL_SUFFIXES: Lazy<HashSet<&'static str>> = Lazy::new(|| {
    [
        "co.uk", "org.uk", "gov.uk", "ac.uk", "net.uk", "me.uk", "ltd.uk", "plc.uk", "sch.uk",
        "co.jp", "ac.jp", "or.jp", "ne.jp", "go.jp", "gr.jp", "ed.jp", "lg.jp",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz", "school.nz",
        "com.br", "net.br", "org.br", "gov.br", "edu.br",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "co.za", "net.za", "org.za", "gov.za", "ac.za",
        "co.kr", "ne.kr", "or.kr", "re.kr", "go.kr", "ac.kr",
        "co.in", "net.in", "org.in", "gov.in", "ac.in",
        "co.il", "net.il", "org.il", "gov.il", "ac.il", "muni.il",
        "com.mx", "net.mx", "org.mx", "gob.mx", "edu.mx",
        "com.ar", "net.ar", "org.ar", "gov.ar",
        "com.hk", "net.hk", "org.hk", "gov.hk", "edu.hk",
        "com.tw", "net.tw", "org.tw", "gov.tw", "edu.tw",
        "com.sg", "net.sg", "org.sg", "gov.sg", "edu.sg", "per.sg",
        "com.tr", "net.tr", "org.tr", "gov.tr", "edu.tr", "k12.tr",
    ]
    .iter()
    .copied()
    .collect()
});

/// Returns the registrable apex for a hostname (port not included).
/// Returns the input unchanged for IPv4 literals, single-label hosts, and
/// hosts already at 2-label apex form.
pub fn registrable_domain(host: &str) -> String {
    if host.is_empty() || IPV4_RE.is_match(host) {
        return host.to_string();
    }
    let labels: Vec<&str> = host.split('.').collect();
    if labels.len() <= 2 {
        return host.to_string();
    }
    let tail2 = format!("{}.{}", labels[labels.len() - 2], labels[labels.len() - 1]);
    if TWO_LABEL_SUFFIXES.contains(tail2.as_str()) {
        return labels[labels.len() - 3..].join(".");
    }
    labels[labels.len() - 2..].join(".")
}
