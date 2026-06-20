//go:build !sqlite

package iriq

import (
	"strings"
	"testing"
)

func TestSlimBuildRejectsSqlitePath(t *testing.T) {
	if HasSqlite {
		t.Fatal("HasSqlite=true in slim build")
	}
	for _, ext := range []string{".db", ".sqlite", ".sqlite3"} {
		s, err := OpenStorage("/tmp/x"+ext, 0)
		if err == nil {
			t.Errorf("%s: expected error, got storage %T", ext, s)
			continue
		}
		if !strings.Contains(err.Error(), "SQLite") {
			t.Errorf("%s: error doesn't mention SQLite: %v", ext, err)
		}
	}
}
