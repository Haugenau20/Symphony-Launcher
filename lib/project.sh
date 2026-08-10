# shellcheck shell=bash
#
# lib/project.sh — per-project identity, paths, and port assignment
#
# Sourced by the `symphony` entry point (not run standalone); see the
# source-order contract there. Pure function definitions, no top-level side
# effects, so this file is safe to source for unit tests. Depends on globals
# defined there (__SYM_DIR) and lib/core.sh (err/warn/info/die).
#
# Every project this file talks about is identified by NAME, never by a repo
# path — there is deliberately no host-repo argument anywhere in this CLI
# (see the per-project layout in lib/symphony.sh). NAME becomes a filesystem
# path component (projects/<name>/...) AND a compose project name
# (symphony-<name>), so it is validated once, here, before it is used as
# either.

# PROJECTS_DIR is relative to the repo root (never `./`-prefixed, matching
# the convention every *_dir helper below follows) — overridable so tests can
# point it at a sandbox.
PROJECTS_DIR="${PROJECTS_DIR:-projects}"

# --- identity ------------------------------------------------------------------

# validate_project_name NAME — die unless NAME matches
# `^[A-Za-z0-9][A-Za-z0-9._-]*$`. This is deliberately the same character
# class the file_queue tracker enforces on an item id (see symphony_wf_scalar
# callers / cmd_add): letters, digits, dot, underscore, dash, and the first
# character must be alnum. Requiring an alnum first character is what rules
# out `.` and `..` as project names (both start with `.`), which matters
# because NAME becomes a literal path segment under PROJECTS_DIR with no
# other containment check — a name of `..` would walk the path straight back
# out of it. A leading `-` is refused too, so NAME can never be mistaken for
# an option by anything that later does `for arg; case "$arg" in -*)`.
validate_project_name() {
  local name="$1"
  if [ -z "${name}" ]; then
    die "project name must not be empty"
  fi
  case "${name}" in
    [A-Za-z0-9]*) : ;;
    *) die "invalid project name '${name}': must start with a letter or digit" ;;
  esac
  case "${name}" in
    *[!A-Za-z0-9._-]*)
      die "invalid project name '${name}': only letters, digits, dot, underscore and dash are allowed" ;;
  esac
}

# --- path derivation -----------------------------------------------------------
# All of these echo a path RELATIVE to the repo root (no leading ./), pure
# string concatenation with no filesystem access — safe to call from
# read-only verbs, and from `check`, which must create nothing on disk.
# Absolute forms (for compose interpolation) are built by prefixing
# $__SYM_DIR — see symphony_derive_settings in lib/symphony.sh.

project_root_dir()        { printf '%s/%s' "${PROJECTS_DIR}" "$1"; }
project_config_dir()      { printf '%s/config' "$(project_root_dir "$1")"; }
project_queue_dir()       { printf '%s/queue' "$(project_root_dir "$1")"; }
project_workspaces_dir()  { printf '%s/workspaces' "$(project_root_dir "$1")"; }
project_env_file()        { printf '%s/.env' "$(project_root_dir "$1")"; }
project_symphony_env_file() { printf '%s/symphony.env' "$(project_root_dir "$1")"; }
project_workflow_file()   { printf '%s/WORKFLOW.md' "$(project_config_dir "$1")"; }
project_allowlist_dir()   { printf '%s/allowlist.d' "$(project_root_dir "$1")"; }

# Container names, matching docker/docker-compose.{yml,symphony.yml,publish.yml}
# exactly (container_name: symphony-${PROJECT_SLUG:-default}-<suffix>).
project_opencode_container_name() { printf 'symphony-%s-opencode' "$1"; }
project_container_name()          { printf 'symphony-%s-orchestrator' "$1"; }
project_publish_container_name()  { printf 'symphony-%s-publish' "$1"; }

# --- port assignment -------------------------------------------------------
# Port publishing is opt-in (`up --publish`) — nothing here runs, and no host
# port is bound, unless that flag is given. recorded_port reads the sticky
# port out of projects/<name>/.env (see its own header below), and the
# running-container probe checks symphony-<name>-publish, matching the
# container name docker-compose.publish.yml actually gives that service.

# port_in_use PORT — return 0 if something is already listening on PORT.
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"
  elif command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$p" >/dev/null 2>&1
  else
    # Fall back to a bash /dev/tcp probe.
    (exec 3<>"/dev/tcp/127.0.0.1/${p}") >/dev/null 2>&1 && { exec 3>&- 3<&- 2>/dev/null; return 0; } || return 1
  fi
}

# viewer_port_for BASE — echo the derived viewer port for BASE: a literal '1'
# prepended (4096 -> 14096). The publisher overlay binds both legs (base and
# viewer), so a base port whose viewer twin is taken is not actually usable.
viewer_port_for() {
  printf '1%s' "$1"
}

# port_pair_free BASE — return 0 iff BASE AND its viewer port are BOTH free.
# Fresh assignment must check both: handing out a base port whose viewer
# port is already bound by something else leaves the publisher unable to
# bind its second leg, breaking `docker compose up` even though BASE itself
# was fine.
port_pair_free() {
  local base="$1"
  ! port_in_use "$base" && ! port_in_use "$(viewer_port_for "$base")"
}

# find_free_port START [LIMIT] — echo the first free port >= START, scanning
# up to LIMIT (exclusive; default START+100). "Free" is the viewer-aware
# sense (port_pair_free), so a candidate whose viewer port is taken is
# skipped too, not just the candidate itself.
find_free_port() {
  local p="$1" limit="${2:-$(( $1 + 100 ))}"
  while [ "$p" -lt "$limit" ] && ! port_pair_free "$p"; do
    p=$((p + 1))
  done
  printf '%s' "$p"
}

# recorded_port NAME — echo the OPENCODE_PORT last written to
# projects/<name>/.env, or nothing if there is no such file/key. Pure read,
# no side effects — safe to call from read-only commands. Deliberately reads
# the FILE rather than the process environment: by the time port assignment
# runs, projects/<name>/.env may already have been loaded into this process
# (see symphony_derive_settings), but the port is meant to be sticky across
# separate invocations of this script, which only a value actually
# persisted on disk can give you.
recorded_port() {
  local name="$1" penv
  penv="$(project_env_file "$name")"
  [ -f "$penv" ] || return 0
  sed -n 's|^OPENCODE_PORT=\(.*\)$|\1|p' "$penv" | tail -n1
}

# publish_container_running NAME — return 0 iff NAME's own publisher
# container (symphony-<name>-publish, from docker/docker-compose.publish.yml)
# is currently up per `docker ps`. This is the "does 4096-being-busy
# actually mean MY stack owns it" check that makes port resolution sticky: a
# project's own running publisher should never be read as a port conflict
# against itself.
publish_container_running() {
  local name="$1"
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$(project_publish_container_name "$name")"
}

# resolve_project_port NAME — echo the port NAME's stack should publish on.
# Only the `up --publish` path calls this — port publishing is opt-in, and
# every other verb never binds a host port at all. The sticky rule, in order:
#   a. if NAME's own publisher container is currently running, reuse the
#      port recorded in projects/<name>/.env (the running stack IS the
#      truth — never treat it as "busy" and bounce it to another port). If
#      somehow running with no recorded port, fall through to the default
#      logic.
#   b. else if a recorded port exists and is currently free, reuse it
#      (sticky across down/up cycles, even after 4096 frees up again).
#   c. else 4096 if free (base AND its viewer port 14096 — see
#      port_pair_free), otherwise the first free port in 4097-4196
#      (find_free_port).
#
# Only the FRESH-assignment branch (c) gets the viewer-port coupling — (a)/(b)
# are sticky reuse of a port this project itself already recorded/is running
# on, and must keep behaving exactly as before (never bounced to a different
# port just because a viewer port looks busy).
resolve_project_port() {
  local name="$1" recorded running=0
  recorded="$(recorded_port "$name")"
  publish_container_running "$name" && running=1

  if [ "$running" -eq 1 ] && [ -n "$recorded" ]; then
    printf '%s' "$recorded"
    return 0
  fi

  if [ "$running" -eq 0 ] && [ -n "$recorded" ] && ! port_in_use "$recorded"; then
    printf '%s' "$recorded"
    return 0
  fi

  if port_pair_free 4096; then
    printf '%s' 4096
    return 0
  fi
  find_free_port 4097 4196
}
