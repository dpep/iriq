# Bash completion for the `iriq` CLI.
#
# Install (pick one):
#   - Persist via Homebrew: brew install dpep/tools/iriq automatically
#     drops this script into Homebrew's bash-completion dir.
#   - Try it out in the current shell:
#       source <(iriq completion bash)
#   - Persist to ~/.bashrc:
#       echo 'source <(iriq completion bash)' >> ~/.bashrc
#   - Or write to your system's bash completion dir:
#       iriq completion bash > /usr/local/etc/bash_completion.d/iriq

_iriq() {
    local cur prev words cword
    _init_completion 2>/dev/null || {
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
    }

    # Argument completion for flags that take a value.
    case "$prev" in
        --corpus)
            # Corpus paths are file-shaped. _filedir picks up *.json / *.db
            # / *.sqlite / *.sqlite3 by default extension; the user can also
            # tab through any path.
            _filedir
            return
            ;;
        --host)
            COMPREPLY=( $(compgen -W "full registrable reg none" -- "$cur") )
            return
            ;;
        --min-observations|--min-hosts|--min-coverage)
            # Numeric argument — no completion candidates.
            return
            ;;
        completion)
            COMPREPLY=( $(compgen -W "bash zsh" -- "$cur") )
            return
            ;;
    esac

    # If the current token starts with `-`, complete flags.
    if [[ "$cur" == -* ]]; then
        local flags="-h --help -V --version -p --parse -n --normalize -e --explain
                     -j --json -J --ndjson -N --no-hints --hints --no-scheme-less
                     --scheme-less --corpus --host --stats --reinfer
                     --propose-recognizers --min-observations --min-coverage --min-hosts"
        COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
        return
    fi

    # First non-flag positional may be a subcommand or a file/IRI.
    if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "cluster completion" -- "$cur") )
        # Also offer files for the auto-extract path (iriq ./access.log).
        local files
        files=$(compgen -f -- "$cur")
        if [[ -n "$files" ]]; then
            COMPREPLY+=( $files )
        fi
        return
    fi

    # Otherwise fall back to file completion (e.g. `iriq cluster <file>`).
    _filedir
}

complete -F _iriq iriq
