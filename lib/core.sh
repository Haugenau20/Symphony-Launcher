# shellcheck shell=bash
#
# lib/core.sh — low-level output and env-file helpers everything else builds on
#
# Sourced by the `symphony` entry point (not run standalone); see the
# source-order contract there. Pure function definitions, no top-level side
# effects, so this file is safe to source for unit tests.

# --- output helpers ----------------------------------------------------------
err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()  { err "$*"; exit 1; }

# --- env-file helpers ---------------------------------------------------------

# load_env FILE — export every `KEY=VALUE` line in FILE into the CURRENT shell
# environment, withOUT sourcing it. Sourcing runs each line as a shell
# command, so an unquoted multi-word value (or, worse, a value an attacker
# controls) becomes something the shell executes rather than a string it
# stores — this reads the file as data instead. Blank lines and `#` comments
# are skipped; anything else that doesn't look like `KEY=...` is silently
# ignored rather than erroring, so a stray line never aborts a boot.
#
# This is the ONE place multiple env files get combined into one process
# environment, and callers rely on being able to invoke it several times in
# sequence — once per layer, in last-wins order (see lib/symphony.sh
# symphony_derive_settings for the exact four-layer order and why it matters).
# Each call's `export` simply overwrites whatever the previous call set, which
# is what makes plain shell assignment do the layering for us.
load_env() {
  local file="$1" line
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%$'\r'}"
    case "${line}" in ''|\#*) continue ;; esac
    case "${line}" in [A-Za-z_]*=*) export "${line}" ;; esac
  done < "${file}"
}

# env_file_get FILE KEY — read KEY's value directly out of an arbitrary env
# file (last matching line wins, same convention as a real shell would give
# a repeated assignment), WITHOUT loading the file into the process
# environment. Used where a check needs to know what one SPECIFIC file says
# — e.g. whether a project's own symphony.env sets SYMPHONY_GITLAB_TOKEN
# itself, as opposed to inheriting it from the shared symphony.env — a
# question process-env alone can't answer once several layers have been
# loaded on top of each other. Missing file is not an error: callers treat
# "file absent" and "key absent" the same way (empty string).
env_file_get() {
  local file="$1" key="$2"
  [ -f "${file}" ] || return 0
  sed -n "s|^${key}=\(.*\)\$|\1|p" "${file}" | tail -n1
}
