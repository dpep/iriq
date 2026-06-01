// Tab-completion support. The `completion` subcommand emits the
// shell-completion script to stdout — pipe into `source` to enable
// completion in the current shell. Homebrew calls this during install
// to drop the scripts into the system's completion directories.
//
//   iriq completion bash    # print the bash script
//   iriq completion zsh     # print the zsh script
//
// The scripts themselves live in completions/{iriq.bash,_iriq} at the
// repo root, embedded into the binary via the parent iriq package so a
// stale install can't drift out of sync with the binary's flag set.

package cli

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/dpep/iriq"
)

// cmdCompletion prints a shell-completion script to stdout. With no
// argument the shell is inferred from $SHELL; pass bash or zsh to
// override. Returns 0 on success, 1 for unknown shells.
func cmdCompletion(args []string, stdout, stderr io.Writer, jsonMode bool) int {
	shell := defaultShell()
	if len(args) > 0 {
		shell = args[0]
	}
	switch shell {
	case "bash":
		fmt.Fprint(stdout, iriq.CompletionBash)
		return 0
	case "zsh":
		fmt.Fprint(stdout, iriq.CompletionZsh)
		return 0
	default:
		return emitError(stderr, jsonMode, "unknown_shell",
			fmt.Sprintf("unknown shell %q (try bash or zsh)", shell), "", 1)
	}
}

// defaultShell returns the basename of $SHELL, defaulting to bash if
// the env var is unset.
func defaultShell() string {
	if s := os.Getenv("SHELL"); s != "" {
		return strings.TrimSuffix(filepath.Base(s), ".exe")
	}
	return "bash"
}
