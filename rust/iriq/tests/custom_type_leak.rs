//! A corpus file can hold any number of custom type names (activated
//! recognizers, or whatever a hand-edited file says). Opening one must retain
//! nothing once the corpus is dropped. Its own test binary: the counting
//! allocator is process-wide.

use iriq::Corpus;
use serde_json::json;
use std::alloc::{GlobalAlloc, Layout, System};
use std::path::Path;
use std::sync::atomic::{AtomicIsize, Ordering};

struct Counting;
static LIVE: AtomicIsize = AtomicIsize::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        LIVE.fetch_add(l.size() as isize, Ordering::SeqCst);
        System.alloc(l)
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        LIVE.fetch_sub(l.size() as isize, Ordering::SeqCst);
        System.dealloc(p, l)
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

fn corpus_with_type_names(path: &Path, tag: &str, n: usize) {
    let type_counts: serde_json::Map<_, _> = (0..n)
        .map(|i| (format!("{tag}_{i:08}_{}", "x".repeat(48)), json!(1)))
        .collect();
    let doc = json!({
        "position_stats": [{
            "position": {"host": "x.com", "scope": "path", "locator": ""},
            "stats": {"total": 1, "value_counts": {}, "type_counts": type_counts}
        }]
    });
    std::fs::write(path, serde_json::to_vec(&doc).unwrap()).unwrap();
}

/// Live heap bytes left behind by opening and dropping the corpus at `path`.
fn retained_by_open(path: &Path) -> isize {
    let before = LIVE.load(Ordering::SeqCst);
    drop(Corpus::open(path).unwrap());
    LIVE.load(Ordering::SeqCst) - before
}

#[test]
fn a_dropped_corpus_retains_none_of_its_custom_type_names() {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("custom-type-leak-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("c.json");
    const N: usize = 10_000;

    // The first open also initializes process-wide statics.
    corpus_with_type_names(&path, "warm", N);
    retained_by_open(&path);

    corpus_with_type_names(&path, "fresh", N);
    assert_eq!(retained_by_open(&path), 0, "bytes retained after drop");
}
