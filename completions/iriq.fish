# Fish completion for the `iriq` CLI.
#
# Install (pick one):
#   - Persist via Homebrew: brew install dpep/tools/iriq drops this file
#     into Homebrew's fish vendor_completions dir automatically.
#   - Try it out in the current shell:
#       iriq completion fish | source
#   - Persist for future sessions:
#       iriq completion fish > ~/.config/fish/completions/iriq.fish

complete -c iriq -s h -l help -d 'show usage'
complete -c iriq -s V -l version -d 'print version'
complete -c iriq -s p -l parse -d 'parsed fields section'
complete -c iriq -s n -l normalize -d 'normalized section'
complete -c iriq -s c -l canonical -d 'canonical form section'
complete -c iriq -s e -l explain -d 'annotated trace section'
complete -c iriq -s j -l json -d 'JSON output'
complete -c iriq -s J -l ndjson -d 'newline-delimited JSON'
complete -c iriq -s N -l no-hints -d 'use {type} placeholders, not {hint}'
complete -c iriq -l hints -d 'enable hint placeholders'
complete -c iriq -l no-scheme-less -d 'skip schemeless URL extraction'
complete -c iriq -l scheme-less -d 'enable schemeless URL extraction'
complete -c iriq -l corpus -r -d 'load/create a JSON or SQLite corpus'
complete -c iriq -l host -x -a 'full registrable reg none' -d 'host-keying strategy for clustering'
complete -c iriq -l stats -d 'print rolling aggregates'
complete -c iriq -l reinfer -d 'replay the source-IRI log'
complete -c iriq -l propose-recognizers -d 'propose new Recognizers from observed shapes'
complete -c iriq -l cross-host-shapes -d 'list route shapes seen across multiple hosts'
complete -c iriq -l activate-above -x -d 'auto-activate proposals at or above this confidence'
complete -c iriq -l min-observations -x -d 'proposal noise floor'
complete -c iriq -l min-coverage -x -d 'proposal coverage floor'
complete -c iriq -l min-hosts -x -d 'threshold for proposals and cross-host shapes'
complete -c iriq -n __fish_use_subcommand -a cluster -d 'force cluster view'
complete -c iriq -n __fish_use_subcommand -a completion -d 'print shell completion script'
complete -c iriq -n '__fish_seen_subcommand_from completion' -x -a 'bash zsh fish'
