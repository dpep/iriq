//! Small Ruby-parity pins: output details the CLI parity harness compares
//! key-order-agnostically, so drift there would go unnoticed.

mod common;

use iriq::{Corpus, ProposalOptions};
use serde_json::{json, Value};
use std::io::Write;
use std::path::PathBuf;
use std::process::Stdio;

fn cluster_json_lines(stdin: &str) -> Vec<Value> {
    let mut child = common::iriq()
        .args(["-C", "cluster", "-J"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("spawn iriq");
    child
        .stdin
        .take()
        .expect("piped stdin")
        .write_all(stdin.as_bytes())
        .expect("write stdin");
    let out = child.wait_with_output().expect("wait for iriq");
    assert!(out.status.success(), "{out:?}");
    String::from_utf8(out.stdout)
        .expect("utf-8 stdout")
        .lines()
        .map(|l| serde_json::from_str(l).expect("NDJSON line"))
        .collect()
}

fn cluster<'a>(clusters: &'a [Value], shape: &str) -> &'a Value {
    clusters
        .iter()
        .find(|c| c["shape"] == shape)
        .unwrap_or_else(|| panic!("no {shape} cluster in {clusters:?}"))
}

fn param<'a>(cluster: &'a Value, name: &str) -> &'a Value {
    cluster["params"]
        .as_array()
        .expect("params array")
        .iter()
        .find(|p| p["name"] == name)
        .unwrap_or_else(|| panic!("no {name} param in {cluster}"))
}

fn keys(map: &Value) -> Vec<&str> {
    map.as_object()
        .unwrap_or_else(|| panic!("not an object: {map}"))
        .keys()
        .map(String::as_str)
        .collect()
}

/// An enum, a number, and a file param in one cluster.
fn items_stream() -> String {
    [
        ("active", 6),
        ("archived", 5),
        ("draft", 4),
        ("pending", 3),
        ("closed", 3),
    ]
    .iter()
    .flat_map(|&(status, n)| std::iter::repeat_n(status, n))
    .enumerate()
    .map(|(i, status)| {
        let n = if i % 2 == 0 {
            i.to_string()
        } else {
            format!("{i}.5")
        };
        let f = if i % 3 == 0 {
            format!("img{i}.png")
        } else {
            format!("doc{i}.pdf")
        };
        format!("https://foo.com/items/1?status={status}&n={n}&f={f}\n")
    })
    .collect()
}

#[test]
fn param_distributions_keep_rubys_key_order() {
    let clusters = cluster_json_lines(&items_stream());
    let items = cluster(&clusters, "/items/{item_id}");

    // Ruby: by descending count, ties by key.
    let status = param(items, "status");
    assert_eq!(status["type"], "enum");
    assert_eq!(
        keys(&status["value_distribution"]),
        ["active", "archived", "draft", "closed", "pending"]
    );
    // Ruby: the subtypes in the order asked for, not by count.
    let n = param(items, "n");
    assert_eq!(n["type"], "number");
    assert_eq!(keys(&n["subtype_distribution"]), ["integer", "float"]);
    let f = param(items, "f");
    assert_eq!(f["type"], "file");
    assert_eq!(keys(&f["kind_distribution"]), ["document", "image"]);
}

#[test]
fn segment_values_list_by_descending_count_then_value() {
    let stdin: String = ["5", "6", "11", "5", "6", "11", "11", "3"]
        .iter()
        .map(|v| format!("https://foo.com/users/{v}\n"))
        .collect();
    let clusters = cluster_json_lines(&stdin);
    let users = cluster(&clusters, "/users/{user_id}");
    assert_eq!(keys(&users["segments"][1]["values"]), ["11", "5", "6", "3"]);
}

const PAT_URL: &str = "https://api.github.com/auth/ghp_zzzz9999xyzzy";

/// A JSON corpus whose views propose `ghp_`, holding `activations` as its
/// stored activations (as though another binary had written them).
fn corpus_holding(name: &str, activations: Value) -> PathBuf {
    let path = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("parity-small-{}-{name}.json", std::process::id()));
    let _ = std::fs::remove_file(&path);
    let mut c = Corpus::open(&path).unwrap();
    for i in 0..25 {
        c.observe(&format!("https://api.github.com/auth/ghp_aaaa{i:04}xyzzy"))
            .unwrap();
    }
    c.save(&path).unwrap();
    drop(c);

    let mut doc = read_json(&path);
    doc["activated_recognizers"] = activations;
    std::fs::write(&path, serde_json::to_vec(&doc).unwrap()).unwrap();
    path
}

fn read_json(path: &PathBuf) -> Value {
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

#[test]
fn reactivating_a_held_recognizer_is_a_no_op_whichever_binary_stored_it() {
    for (writer, specificity) in [("ruby", 1.0), ("older-rust", 0.3)] {
        let held = json!([{"prefix": "ghp_", "type": "ghp", "specificity": specificity}]);
        let path = corpus_holding(writer, held.clone());
        let mut c = Corpus::open(&path).unwrap();
        // Specificity never decides a synthesized recognizer's verdict.
        assert_eq!(
            c.normalize(PAT_URL).unwrap(),
            "https://api.github.com/auth/{ghp}",
            "{writer}"
        );
        // The views predate the activation, so they still propose it.
        let proposals = c.propose_recognizers(ProposalOptions::default()).unwrap();
        assert!(
            proposals
                .iter()
                .any(|p| p.prefix == "ghp_" && p.confidence >= 0.9),
            "{writer}: {proposals:?}"
        );

        let activated = c
            .activate_proposals_above(0.9, ProposalOptions::default())
            .unwrap();
        assert!(activated.is_empty(), "{writer}: {activated:?}");
        c.save(&path).unwrap();
        drop(c);
        assert_eq!(read_json(&path)["activated_recognizers"], held, "{writer}");
        std::fs::remove_file(&path).ok();
    }
}

#[test]
fn activation_stores_rubys_specificity() {
    let path = corpus_holding("fresh", json!([]));
    let mut c = Corpus::open(&path).unwrap();
    let activated = c
        .activate_proposals_above(0.9, ProposalOptions::default())
        .unwrap();
    assert_eq!(activated.len(), 1);
    c.save(&path).unwrap();
    drop(c);

    // Ruby's Specificity::SEMANTIC.
    assert_eq!(
        read_json(&path)["activated_recognizers"],
        json!([{"prefix": "ghp_", "type": "ghp", "specificity": 1.0}])
    );
    std::fs::remove_file(&path).ok();
}
