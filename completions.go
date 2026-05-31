package iriq

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
