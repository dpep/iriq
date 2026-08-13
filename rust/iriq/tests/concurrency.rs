//! The SQLite backend claims to support concurrent observers (WAL journaling
//! plus a busy_timeout). Prove it: spawn N threads that each open the SAME
//! .db corpus — including racing to initialize it from scratch — and observe
//! a disjoint slice of URLs. The reopened corpus must contain every
//! observation with consistent aggregates.
#![cfg(feature = "sqlite")]

use iriq::Corpus;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

const WRITERS: usize = 4;
const URLS_PER_THREAD: usize = 50;

fn temp_path(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("iriq_concurrency_{}_{}", std::process::id(), name))
}

fn cleanup(p: &Path) {
    let base = p.to_str().unwrap();
    for side in [
        base.to_string(),
        format!("{base}-wal"),
        format!("{base}-shm"),
    ] {
        let _ = std::fs::remove_file(side);
    }
}

#[test]
fn concurrent_observers_against_the_same_corpus_file() {
    let p = temp_path("writers.db");
    cleanup(&p);
    let path = p.to_str().unwrap().to_string();

    let handles: Vec<_> = (0..WRITERS)
        .map(|i| {
            let path = path.clone();
            std::thread::spawn(move || {
                let mut corpus = Corpus::open(&path).expect("concurrent open failed");
                for j in 0..URLS_PER_THREAD {
                    let url = format!("https://c{i}.example.com/users/{}", i * URLS_PER_THREAD + j);
                    corpus.observe(&url).expect("observe failed");
                }
                corpus.close().expect("close failed");
            })
        })
        .collect();
    for h in handles {
        h.join().expect("concurrent observer panicked");
    }

    let corpus = Corpus::open(&path).unwrap();
    let total = WRITERS * URLS_PER_THREAD;

    assert_eq!(corpus.observed_iri_count(), total);

    let expected_hosts: HashMap<String, usize> = (0..WRITERS)
        .map(|i| (format!("c{i}.example.com"), URLS_PER_THREAD))
        .collect();
    assert_eq!(corpus.host_counts(), expected_hosts);

    assert_eq!(corpus.raw_shape_counts().values().sum::<usize>(), total);
    assert_eq!(
        corpus.clusters().iter().map(|c| c.count).sum::<usize>(),
        total
    );
    cleanup(&p);
}
