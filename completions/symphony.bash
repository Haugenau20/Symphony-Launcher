# Bash completion for ./symphony.
#
# Install (pick one):
#   source completions/symphony.bash                          # this session only
#   echo 'source /path/to/completions/symphony.bash' >> ~/.bashrc
#   sudo cp completions/symphony.bash /etc/bash_completion.d/symphony
#
# Completes the verb, then a project name for every verb that takes one
# (read from projects/*/, excluding the _example template), then --publish
# and --with-review after `up`. The verb list is a maintained static copy —
# keep it in sync with usage() in ../symphony whenever a verb is
# added/removed/renamed there.

_symphony_verbs=(
  init check up logs status stop down add config
  projects version help
)

# Verbs of the form `symphony <verb> <name> [...]`. `projects`, `version` and
# `help` take no project name.
_symphony_name_verbs=(
  init check up logs status stop down add config
)

# List project directories under ./projects, minus the _example template.
# Run relative to $PWD deliberately: symphony itself is only ever run from
# inside a checkout (or via a PATH shim that cds into one first), so this
# matches what the command being completed will actually resolve.
_symphony_project_names() {
  local d
  [ -d projects ] || return 0
  for d in projects/*/; do
    [ -d "$d" ] || continue
    d="${d#projects/}"
    d="${d%/}"
    [ "$d" = "_example" ] && continue
    printf '%s\n' "$d"
  done
}

_symphony_complete() {
  local cur prev verb
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]:-}"
  verb="${COMP_WORDS[1]:-}"

  # First word after `symphony` itself: offer the verb list.
  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=($(compgen -W "${_symphony_verbs[*]}" -- "$cur"))
    return 0
  fi

  local v
  for v in "${_symphony_name_verbs[@]}"; do
    if [ "$verb" = "$v" ]; then
      # A word starting with '-' is a flag, not a project name. --publish and
      # --with-review are the only flags, and only `up` accepts either.
      if [ "${cur:0:1}" = "-" ]; then
        if [ "$verb" = "up" ]; then
          COMPREPLY=($(compgen -W "--publish --with-review" -- "$cur"))
        fi
        return 0
      fi
      COMPREPLY=($(compgen -W "$(_symphony_project_names)" -- "$cur"))
      return 0
    fi
  done

  # projects / version / help / anything unrecognised: nothing further to
  # complete.
  return 0
}

complete -F _symphony_complete symphony
complete -F _symphony_complete ./symphony
