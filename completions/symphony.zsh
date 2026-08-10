#compdef symphony ./symphony
#
# Zsh completion for ./symphony.
#
# Install (pick one):
#   source completions/symphony.zsh                            # this session only
#   echo 'source /path/to/symphony-launcher/completions/symphony.zsh' >> ~/.zshrc
#   # or drop it on your $fpath as a function named _symphony
#   # (rename the file to drop the .zsh extension) and let compinit pick it up.
#
# Completes the verb, then a project name for every verb that takes one
# (read from projects/*/, excluding the _example template), then --publish
# after `up`. The verb list is a maintained static copy — keep it in sync
# with usage() in ../symphony whenever a verb is added/removed/renamed there.

# List project directories under ./projects, minus the _example template, one
# per line. Plain POSIX-ish glob/loop (no zsh-only glob qualifiers) so this
# also parses cleanly under `bash -n` for the repo's own syntax checks.
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

_symphony() {
  local -a verbs
  verbs=(
    'init:scaffold a new project under projects/<name>'
    'check:preflight — validate config without starting anything'
    'up:start a project'\''s stack'
    'logs:follow a project'\''s logs'
    'status:queue counts / stack state for a project'
    'stop:stop a project'\''s stack'
    'down:tear a project'\''s stack down'
    'add:queue a work item (file_queue tracker only)'
    'config:print a project'\''s fully-resolved config'
    'projects:list known projects'
    'version:print the launcher version'
    'help:show usage'
  )

  # words[1] is the command name itself (symphony / ./symphony); words[2] is
  # the verb once typed.
  if (( CURRENT == 2 )); then
    _describe -t commands 'symphony command' verbs
    return
  fi

  local verb="${words[2]}"
  case "$verb" in
    init|check|up|logs|status|stop|down|add|config)
      if [[ "$words[CURRENT]" == -* ]]; then
        if [[ "$verb" == "up" ]]; then
          _values '' '--publish[attach the debug publisher overlay (docker-compose.publish.yml)]'
        fi
        return
      fi
      local -a names
      names=()
      local line
      while IFS= read -r line; do
        [ -n "$line" ] && names+=("$line")
      done < <(_symphony_project_names)
      _describe -t projects 'project' names
      ;;
    *)
      # projects / version / help / anything unrecognised: nothing further.
      ;;
  esac
}

# Only invoke when running inside zsh's completion system (i.e. _describe is
# available). Plain `source`-ing this file (e.g. a syntax smoke test, or a
# `bash -n` check from the repo's own tooling) must be a no-op rather than
# erroring with "command not found: _describe".
if whence -w _describe >/dev/null 2>&1; then
  _symphony "$@"
fi
