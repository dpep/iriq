//! Small Ruby-parity pins: output details the CLI parity harness compares
//! key-order-agnostically, so drift there would go unnoticed.

mod common;

use serde_json::Value;
use std::io::Write;
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
