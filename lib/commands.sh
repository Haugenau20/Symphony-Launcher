# shellcheck shell=bash
#
# lib/commands.sh — the verb implementations: init, check, up, logs, status,
# stop, down, add, config, projects.
#
# Sourced by the `symphony` entry point (not run standalone); see the
# source-order contract there. Pure function definitions, no top-level side
# effects, so this file is safe to source for unit tests. Depends on globals
# defined there (__SYM_DIR, ENV_FILE) and helpers from lib/core.sh,
# lib/project.sh and lib/symphony.sh.

# --- init ----------------------------------------------------------------------

# cmd_init NAME — scaffold projects/<name>/ and print next steps. Idempotent:
# safe to run again on an existing project (never overwrites an existing
# file, and mkdir -p never complains about an existing directory).
cmd_init() {
  local name="${1:-}"
  [ -n "$name" ] || { usage; die "init requires a project name"; }
  validate_project_name "$name"

  local root config_dir queue_dir workspaces_dir workflow agent_env sym_env
  root="$(project_root_dir "$name")"
  config_dir="$(project_config_dir "$name")"
  queue_dir="$(project_queue_dir "$name")"
  workspaces_dir="$(project_workspaces_dir "$name")"
  workflow="$(project_workflow_file "$name")"
  agent_env="$(project_env_file "$name")"
  sym_env="$(project_symphony_env_file "$name")"

  # Creates config/ and workspaces/ always, plus the six file_queue state
  # dirs unless an existing WORKFLOW.md already says tracker: gitlab — see
  # symphony_ensure_dirs.
  symphony_ensure_dirs "$name"

  # projects/<name>/.env and symphony.env from the shipped per-project
  # example (projects/_example/, the one directory under projects/ that stays
  # tracked — see projects/README.md), if not already present. A checkout
  # missing that directory is degraded rather than broken, so print the copy
  # command instead of failing: `init` is the verb people reach for when
  # something is already wrong, and it should still say what to do next.
  local example
  if [ ! -f "$agent_env" ]; then
    example="projects/_example/.env.example"
    if [ -f "$example" ]; then
      cp "$example" "$agent_env"
      info "created $agent_env (from $example)"
    else
      info "no $example found yet — create $agent_env by hand, or once it ships:"
      info "  cp $example $agent_env"
    fi
  else
    info "$agent_env already present"
  fi

  if [ ! -f "$sym_env" ]; then
    example="projects/_example/symphony.env.example"
    if [ -f "$example" ]; then
      cp "$example" "$sym_env"
      info "created $sym_env (from $example)"
    else
      info "no $example found yet — create $sym_env by hand, or once it ships:"
      info "  cp $example $sym_env"
    fi
  else
    info "$sym_env already present"
  fi

  info "scaffolded $root"
  info "  config:     $config_dir"
  info "  queue:      $queue_dir (file_queue state — unused under tracker: gitlab)"
  info "  workspaces: $workspaces_dir"
  echo
  if [ -f "$workflow" ]; then
    info "WORKFLOW.md already present: $workflow"
  else
    info "next: copy a workflow template and edit it:"
    info "  cp templates/WORKFLOW.md.example $workflow          # file queue"
    info "  cp templates/WORKFLOW.gitlab.md.example $workflow   # GitLab issues"
    info "  \$EDITOR $workflow"
  fi
  echo
  info "gitlab tracker only — put a Reporter-role project token in $sym_env:"
  info "  echo 'SYMPHONY_GITLAB_TOKEN=<token>' >> $sym_env"
  info "  (never in .env or $agent_env — see the README's 'The security model')"
  echo
  info "then:"
  info "  symphony check $name"
  info "  symphony up    $name"
}

# --- check -----------------------------------------------------------------------

# cmd_check NAME — preflight only. MUST create nothing on disk: derive
# settings + preflight are both pure reads, and symphony_ensure_dirs is
# deliberately never called here. When docker is on PATH, also resolves the
# full compose config and asserts SYMPHONY_GITLAB_TOKEN's value never
# appears in the opencode service's block of it — the belt-and-braces check
# on top of every preflight check that's supposed to keep it out in the
# first place.
cmd_check() {
  local name="${1:-}"
  [ -n "$name" ] || { usage; die "check requires a project name"; }
  validate_project_name "$name"
  [ -f "$ENV_FILE" ] || die "no $ENV_FILE found — copy .env.example to $ENV_FILE and edit it first."
  [ -d "$(project_root_dir "$name")" ] || die "no such project: $(project_root_dir "$name") — run: symphony init $name"

  local PROJECT_SLUG PROJECT_ENV_FILE COMPOSE
  local SYM_CONFIG_DIR SYM_QUEUE_DIR SYM_WORKSPACES_DIR SYM_ENV_FILE SYM_SYMPHONY_ENV_FILE SYM_WORKFLOW SYM_ALLOWLIST_DIR SYM_CONTAINER
  symphony_derive_settings "$name"

  local failed=0
  symphony_preflight "$name" || failed=1

  if [ "$failed" -ne 0 ]; then
    return 1
  fi

  if command -v docker >/dev/null 2>&1; then
    info "cross-checking 'docker compose config' for a leaked SYMPHONY_GITLAB_TOKEN ..."
    local token="${SYMPHONY_GITLAB_TOKEN:-}"
    if [ -n "$token" ]; then
      local resolved opencode_block
      resolved="$("${COMPOSE[@]}" config 2>/dev/null)" || resolved=""
      # One token configured for BOTH roles would also match the search below,
      # for a completely different reason and with a different fix. That case
      # is fatal in symphony_preflight above, so it cannot reach here — and
      # GITLAB_PAT's own value is excluded from the block anyway, so this
      # check reports only the thing it names: a Reporter token that arrived
      # in the agent's environment through the env layering.
      resolved="$(printf '%s\n' "$resolved" | grep -vE '^[[:space:]]*GITLAB_PAT:[[:space:]]' || true)"
      # Isolate the `opencode:` service block among its siblings under
      # `services:` (2-space-indented keys), so a token that legitimately
      # appears in the SYMPHONY service's own block (that IS the mechanism
      # — see the header of lib/symphony.sh) never produces a false alarm
      # here. Any line indented deeper than 2 spaces belongs to the current
      # block; the next 2-space (or 0-space, e.g. `networks:`) line ends it.
      opencode_block="$(printf '%s\n' "$resolved" | awk '
        /^  opencode:/ { grab=1; print; next }
        grab && /^([A-Za-z]|  [A-Za-z])/ { grab=0 }
        grab { print }
      ')"
      if [ -n "$opencode_block" ] && printf '%s' "$opencode_block" | grep -qF -- "$token"; then
        err "  SYMPHONY_GITLAB_TOKEN's value appears in the resolved opencode service config"
        err "    it must never reach the agent's container — see lib/symphony.sh's header"
        failed=1
      else
        info "  PASS: SYMPHONY_GITLAB_TOKEN does not appear in the opencode service's resolved config"
      fi
    else
      info "  no SYMPHONY_GITLAB_TOKEN set — nothing to check"
    fi
  else
    warn "docker not found on PATH — skipping the compose-config credential cross-check"
  fi

  if [ "$failed" -eq 0 ]; then
    info "check passed."
    return 0
  fi
  return 1
}

# --- up --------------------------------------------------------------------------

# cmd_up NAME [--publish] — preflight (abort before any docker call on
# failure), create dirs, pull, then start opencode+squid+symphony (plus the
# `publish` service only with --publish, which is the only path that ever
# binds a host port).
cmd_up() {
  local name="" publish=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --publish) publish=1; shift ;;
      -*) die "unknown option: $1" ;;
      *)
        if [ -n "$name" ]; then die "unexpected extra argument: $1"; fi
        name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || { usage; die "up requires a project name"; }
  validate_project_name "$name"
  [ -f "$ENV_FILE" ] || die "no $ENV_FILE found — copy .env.example to $ENV_FILE and edit it first."
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH. Install Docker first."

  local PROJECT_SLUG PROJECT_ENV_FILE COMPOSE
  local SYM_CONFIG_DIR SYM_QUEUE_DIR SYM_WORKSPACES_DIR SYM_ENV_FILE SYM_SYMPHONY_ENV_FILE SYM_WORKFLOW SYM_ALLOWLIST_DIR SYM_CONTAINER
  symphony_derive_settings "$name"

  symphony_preflight "$name" \
    || die "preflight failed — nothing started. Fix the above and re-run, or run 'symphony check $name' for detail only."

  symphony_ensure_dirs "$name"

  if [ "$publish" -eq 1 ]; then
    local port
    port="$(resolve_project_port "$name")"
    export OPENCODE_PORT="$port"
    info "publishing on port $port (viewer $(viewer_port_for "$port"))"
    COMPOSE+=(-f "$__SYM_DIR/docker/docker-compose.publish.yml")
  fi

  # A missing `-symphony` tag in the registry is expected until it has been
  # published — this repo is pull-only (see docker/docker-compose.symphony.yml's
  # header). A pull failure here is not a bug in this launcher.
  info "pulling images for symphony-${name} (opencode, squid, symphony) ..."
  info "  note: a missing '-symphony' tag in the registry is expected until a release is cut"
  "${COMPOSE[@]}" pull opencode squid symphony

  if [ "$publish" -eq 1 ]; then
    info "starting symphony-${name} (opencode + squid + symphony + publish) ..."
    "${COMPOSE[@]}" up -d opencode squid symphony publish
  else
    info "starting symphony-${name} (opencode + squid + symphony; no published port) ..."
    "${COMPOSE[@]}" up -d opencode squid symphony
  fi

  echo
  symphony_queue_status "$name"
  echo
  info "logs:  symphony logs $name"
  info "stop:  symphony stop $name"
}

# --- logs ------------------------------------------------------------------------

# cmd_logs NAME — follow the orchestrator's log. No-ops (not an error) when
# the orchestrator container is not running, rather than calling compose at
# all.
cmd_logs() {
  local name="${1:-}"
  [ -n "$name" ] || { usage; die "logs requires a project name"; }
  validate_project_name "$name"
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH. Install Docker first."

  local PROJECT_SLUG PROJECT_ENV_FILE COMPOSE
  local SYM_CONFIG_DIR SYM_QUEUE_DIR SYM_WORKSPACES_DIR SYM_ENV_FILE SYM_SYMPHONY_ENV_FILE SYM_WORKFLOW SYM_ALLOWLIST_DIR SYM_CONTAINER
  symphony_derive_settings "$name"

  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$SYM_CONTAINER"; then
    info "$SYM_CONTAINER is not running — nothing to tail. Start it with: symphony up $name"
    return 0
  fi

  info "tailing logs for $SYM_CONTAINER (Ctrl-C detaches; the stack keeps running) ..."
  "${COMPOSE[@]}" logs -f --tail=100 symphony
}

# --- status ----------------------------------------------------------------------

# cmd_status NAME — per-state queue counts (file_queue) or the tracker's
# project/board (gitlab — never file counts, see symphony_queue_status),
# plus whether the orchestrator container is running.
cmd_status() {
  local name="${1:-}"
  [ -n "$name" ] || { usage; die "status requires a project name"; }
  validate_project_name "$name"

  info "project: symphony-${name}  (orchestrator: $(project_container_name "$name"))"
  symphony_queue_status "$name"
}

# --- stop ------------------------------------------------------------------------

# cmd_stop NAME — stop the orchestrator only; opencode/squid keep running.
# In-flight items stay in in-progress/ and resume on restart (the file_queue
# claim is a rename(2), not a lease, so nothing times it out).
cmd_stop() {
  local name="${1:-}"
  [ -n "$name" ] || { usage; die "stop requires a project name"; }
  validate_project_name "$name"
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH. Install Docker first."
  if [ ! -f "$ENV_FILE" ]; then
    info "no $ENV_FILE found — nothing has ever been started."
    return 0
  fi

  local PROJECT_SLUG PROJECT_ENV_FILE COMPOSE
  local SYM_CONFIG_DIR SYM_QUEUE_DIR SYM_WORKSPACES_DIR SYM_ENV_FILE SYM_SYMPHONY_ENV_FILE SYM_WORKFLOW SYM_ALLOWLIST_DIR SYM_CONTAINER
  symphony_derive_settings "$name"

  info "stopping $SYM_CONTAINER ..."
  "${COMPOSE[@]}" stop symphony
  info "symphony stopped. opencode/squid keep running. In-flight items stay in in-progress/ and resume on restart."
}

# --- down ------------------------------------------------------------------------

# cmd_down NAME — tear down the whole stack (opencode + squid + symphony,
# plus the publish service if it was ever brought up — `down` with no service list
# tears down everything compose knows about for this project, published or
# not).
cmd_down() {
  local name="${1:-}"
  [ -n "$name" ] || { usage; die "down requires a project name"; }
  validate_project_name "$name"
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH. Install Docker first."
  if [ ! -f "$ENV_FILE" ]; then
    info "no $ENV_FILE found — nothing has ever been started."
    return 0
  fi

  local PROJECT_SLUG PROJECT_ENV_FILE COMPOSE
  local SYM_CONFIG_DIR SYM_QUEUE_DIR SYM_WORKSPACES_DIR SYM_ENV_FILE SYM_SYMPHONY_ENV_FILE SYM_WORKFLOW SYM_ALLOWLIST_DIR SYM_CONTAINER
  symphony_derive_settings "$name"

  info "tearing down symphony-${name} (opencode + squid + symphony stack) ..."
  if "${COMPOSE[@]}" down; then
    info "symphony-${name} is down."
  else
    warn "compose down reported an error for symphony-${name} (it may not have been running)."
  fi
}

# --- add -------------------------------------------------------------------------

# cmd_add NAME BODY [--id ID] [--title TITLE] — queue a new file_queue item.
# Refuses outright under tracker: gitlab, where a file in todo/ is read by
# nothing: writing one and reporting success would leave the caller waiting
# on work that was never queued. The `^[A-Za-z0-9]` id check matches the
# tracker's own id regex, so a manually-set --id is guaranteed valid to the
# component that will actually read it.
cmd_add() {
  local name="${1:-}"
  [ -n "$name" ] || { usage; die "add requires a project name"; }
  shift || true
  validate_project_name "$name"

  local workflow queue_dir
  workflow="$(project_workflow_file "$name")"
  queue_dir="$(project_queue_dir "$name")"

  if [ "$(symphony_tracker_kind "$workflow")" = "gitlab" ]; then
    err "the tracker is gitlab — work items are GitLab issues, not files."
    err "  create an issue and label it $(symphony_wf_scalar "$workflow" label_prefix)::todo"
    exit 1
  fi

  [ "$#" -ge 1 ] || { usage; die "usage: symphony add $name \"what the agent should do\" [--id ID] [--title TITLE]"; }
  local body="$1"; shift
  local id="" title=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id)    id="${2:-}"; shift 2 ;;
      --title) title="${2:-}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done

  symphony_ensure_dirs "$name"

  [ -n "$id" ] || id="SYM-$(date +%Y%m%d-%H%M%S)"
  case "$id" in
    [A-Za-z0-9]*) : ;;
    *) die "id must start with a letter or digit: $id" ;;
  esac
  [ -n "$title" ] || title="${body%%$'\n'*}"

  local slug_title file now
  slug_title="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | cut -c1-40 | sed 's/-$//')"
  file="${queue_dir}/todo/${id}-${slug_title}.md"
  [ ! -e "$file" ] || die "already exists: $file"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$file" <<ITEM
---
id: ${id}
title: ${title}
priority: 5
labels: []
blocked_by: []
branch: null
attempts: 0
next_retry_at: null
session_id: null
created_at: ${now}
updated_at: ${now}
---

${body}
ITEM
  info "queued $file"
}

# --- config ----------------------------------------------------------------------

# cmd_config NAME [ARGS...] — print the fully resolved `docker compose
# config`. Exists because four env layers plus derivation is more than a
# human can resolve by reading the files by eye — this prints what they
# actually resolved to, the same object compose itself will act on.
cmd_config() {
  local name="${1:-}"
  [ -n "$name" ] || { usage; die "config requires a project name"; }
  shift || true
  validate_project_name "$name"
  [ -f "$ENV_FILE" ] || die "no $ENV_FILE found — copy .env.example to $ENV_FILE and edit it first."

  local PROJECT_SLUG PROJECT_ENV_FILE COMPOSE
  local SYM_CONFIG_DIR SYM_QUEUE_DIR SYM_WORKSPACES_DIR SYM_ENV_FILE SYM_SYMPHONY_ENV_FILE SYM_WORKFLOW SYM_ALLOWLIST_DIR SYM_CONTAINER
  symphony_derive_settings "$name"

  "${COMPOSE[@]}" config "$@"
}

# --- projects --------------------------------------------------------------------

# cmd_projects — `ls projects/` with the two facts you cannot see from the
# directory name: which tracker it is on, and whether it is up. Reads each
# project's own files directly rather than re-entering this script (and its
# full four-layer derivation) once per project — nothing here needs that.
cmd_projects() {
  # -d first: `find`/a glob on a missing PROJECTS_DIR must never abort the
  # script under `set -o pipefail` — reachable on a totally fresh checkout
  # that has never run `init`. _example/ is excluded from the emptiness
  # check too — a checkout that has only ever had `_example` (the template
  # `init` reads from, never a real project) is exactly the same "nothing
  # deployed yet" situation as no projects/ subdirectories at all.
  if [ ! -d "$PROJECTS_DIR" ] \
     || [ -z "$(find "$PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d -not -name _example 2>/dev/null)" ]; then
    info "no projects yet — create one with:"
    info "  symphony init <name>"
    return 0
  fi

  printf '  %-20s %-10s %-7s %s\n' NAME TRACKER PORT STATE
  local d name wf kind port container_orch state
  for d in "$PROJECTS_DIR"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    # _example/ ships as a template `init` reads from, not a real project —
    # see projects/README.md. Never runs against it directly, so it has no
    # business in a list of what's actually deployed.
    if [ "$name" = "_example" ]; then continue; fi
    wf="${d}config/WORKFLOW.md"
    kind="-"
    if [ -f "$wf" ]; then
      kind="$(symphony_tracker_kind "$wf")"
      [ -n "$kind" ] || kind="-"
    fi
    # The port is read, not resolved: it only means anything once `up
    # --publish` has assigned and recorded one. -f first: sed on a missing
    # file returns non-zero even with stderr silenced, and under
    # `set -o pipefail` that would abort this whole loop on the very common
    # case of a project with no .env yet (e.g. right after `init`).
    port="-"
    if [ -f "${d}.env" ]; then
      port="$(sed -n 's|^OPENCODE_PORT=\(.*\)$|\1|p' "${d}.env" | tail -n1)"
      [ -n "$port" ] || port="-"
    fi
    container_orch="$(project_container_name "$name")"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container_orch"; then
      state="symphony up"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$(project_opencode_container_name "$name")"; then
      state="opencode up"
    else
      state="-"
    fi
    printf '  %-20s %-10s %-7s %s\n' "$name" "$kind" "$port" "$state"
  done
  echo
  info "use one:  symphony check <name>"
}
