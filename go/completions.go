package iriq

// go/completions/ is the Go binary's own copy of the shell-completion
// scripts: go:embed cannot reach files outside the package directory, so
// it can't share the repo-root completions/ that the Ruby gem ships. The
// Rust CLI likewise carries its own copy. Keep the three in sync when a
// flag changes (same discipline as the cross-runtime fixtures).

import _ "embed"

// CompletionBash is the bash completion script for the iriq CLI,
// embedded from completions/iriq.bash. Emitted by `iriq completion bash`.
//
//go:embed completions/iriq.bash
var CompletionBash string

// CompletionZsh is the zsh completion script for the iriq CLI, embedded
// from completions/_iriq. Emitted by `iriq completion zsh`.
//
//go:embed completions/_iriq
var CompletionZsh string
