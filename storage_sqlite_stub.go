//go:build !sqlite

package iriq

import "errors"

// HasSqlite reports whether this build includes the SQLite storage backend.
// Toggle by compiling with `-tags sqlite`.
const HasSqlite = false

// SqliteStorage is a stub type kept so callers can name it unconditionally
// (e.g. type switches). The slim build never actually instantiates it.
type SqliteStorage struct{}

// OpenSqliteStorage returns an error in the slim build. Rebuild with
// `-tags sqlite` (or `brew install dpep/tools/iriq-sqlite`) to enable.
func OpenSqliteStorage(path string, maxValues int) (Storage, error) {
	return nil, errors.New("iriq was built without SQLite support — rebuild with -tags sqlite or install iriq-sqlite")
}

// OpenSqliteStorageWith mirrors the tagged-build signature; same error.
func OpenSqliteStorageWith(path string, maxValues int, c *SegmentClassifier) (Storage, error) {
	return OpenSqliteStorage(path, maxValues)
}
