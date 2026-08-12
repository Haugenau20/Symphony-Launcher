# shellcheck shell=bash
#
# lib/symphony.sh — WORKFLOW.md parsing, the allowlist cross-check, the
# four-layer env derivation, and preflight.
#
# Sourced by the `symphony` entry point (not run standalone); see the
# source-order contract there. Pure function definitions, no top-level side
# effects, so this file is safe to source for unit tests. Depends on globals
# defined there (__SYM_DIR, ENV_FILE, SYMPHONY_ENV) and helpers from
# lib/core.sh (info/warn/err/die, load_env, env_file_get) and lib/project.sh
# (validate_project_name, project_*_dir/file, project_*_container_name).
#
# Design (see the README's "Configuration: four layers" for the full
# rationale):
#
#   projects/<name>/
#   ├── .env             per-project, AGENT-visible   -> PROJECT_ENV_FILE
#   ├── symphony.env     per-project, LAUNCHER-ONLY    -> --env-file only
#   ├── config/
#   │   └── WORKFLOW.md  -> SYMPHONY_CONFIG_PATH, bind-mounted ro into the
#   │                       symphony container. config/ is a SUBDIRECTORY of
#   │                       projects/<name>/, one level below symphony.env,
#   │                       so that mount can never expose it — see
#   │                       symphony_preflight.
#   ├── queue/           -> SYMPHONY_QUEUE_PATH (six file_queue state dirs;
#   │                       unused under tracker: gitlab)
#   ├── workspaces/      -> SYMPHONY_WORKSPACES_PATH (per-item agent
#   │                       workspaces; used by both trackers)
#   └── allowlist.d/     -> EXTRA_ALLOWLIST_PATH, opt-in: only exported when
#                           the directory exists
#
# THE INVARIANT THAT MATTERS MOST: SYMPHONY_GITLAB_TOKEN must never reach the
# agent's container. Mechanically, projects/<name>/symphony.env (and the
# shared root symphony.env) are passed to compose ONLY via `--env-file` —
# that drives ${VAR} interpolation and puts nothing in a container by
# itself. The only place the token actually lands inside a container is the
# symphony service's own `environment:` block in
# docker/docker-compose.symphony.yml. Never write it into projects/<name>/.env,
# never into the root .env, and never generate a concatenated env file that
# includes it — see symphony_preflight's leak checks, which are what catch a
# mistake here.

# SYMPHONY_ENV is the shared, launcher-only root file (the counterpart to the
# per-project projects/<name>/symphony.env). Never named by docker-compose.yml's
# `env_file:` directive, for the same reason as its per-project counterpart.
SYMPHONY_ENV="${SYMPHONY_ENV:-symphony.env}"

# --- WORKFLOW.md front-matter parsing ------------------------------------------
# Sed-only (no yaml parser dependency): the front matter is delimited by two
# `---` lines.

# symphony_tracker_kind WORKFLOW — echo `tracker.kind` (e.g. "file_queue" or
# "gitlab"), or empty if the file/key is missing.
symphony_tracker_kind() {
  local workflow="$1"
  [ -f "$workflow" ] || return 0
  sed -n '/^---$/,/^---$/p' "$workflow" \
    | sed -n 's/^[[:space:]]*kind:[[:space:]]*\([a-z_]*\).*/\1/p' | head -1
}

# symphony_wf_scalar WORKFLOW KEY — the first top-level `key: value` in the
# front matter, comments and surrounding quotes stripped. A commented-out
# line never matches: KEY must start the line (after indentation).
symphony_wf_scalar() {
  local workflow="$1" key="$2"
  [ -f "$workflow" ] || return 0
  sed -n '/^---$/,/^---$/p' "$workflow" \
    | sed -n "s/^[[:space:]]*${key}:[[:space:]]*\(.*\)\$/\1/p" | head -1 \
    | sed 's/[[:space:]]#.*$//; s/[[:space:]]*$//; s/^["'"'"']//; s/["'"'"']$//'
}

# symphony_wf_body WORKFLOW — everything AFTER the front matter's closing
# `---` line: the agent's prompt template. Used by the completion-marker and
# gitlab clone-URL checks below, which both need to search prose rather than
# front-matter keys. Front matter is delimited by the FIRST two `---` lines
# in the file; everything from the second one onward is body, including any
# `---` that appears later inside the prompt text itself.
symphony_wf_body() {
  local workflow="$1"
  [ -f "$workflow" ] || return 0
  awk '/^---$/{c++; next} c>=2{print}' "$workflow"
}

# --- allowlist agreement --------------------------------------------------------
# GIT_REMOTE_ALLOWLIST (git plane, enforced by the image's git-guard) and
# GITLAB_WRITE_PROJECTS (API plane, enforced by the MCP write gate) express
# nearly the same intent in two formats, and nothing at runtime makes them
# agree — different processes gating different protocols. See
# docs/IMAGE_CONTRACT.md for the full contract.

# symphony_norm_dest URL|PATH — reduce a destination to `host/path`, or a
# bare project path when there is no host. Drops scheme, userinfo, port,
# trailing `.git` and surrounding slashes, and lowercases. Same
# normalization as git-guard's normalize_remote and the MCP gate's
# normalizeProject, so all three agree on what an entry means.
symphony_norm_dest() {
  local url="${1}" host rest
  url="${url%%\?*}"
  case "${url}" in
    *://*)
      url="${url#*://}"; url="${url#*@}"
      host="${url%%/*}"; rest=""
      case "${url}" in */*) rest="/${url#*/}" ;; esac
      host="${host%%:*}"; url="${host}${rest}"
      ;;
    /*|./*|../*|~*) ;;
    *:*) url="${url#*@}"; url="${url%%:*}/${url#*:}" ;;
  esac
  url="${url#/}"; url="${url%/}"; url="${url%.git}"
  printf '%s' "${url}" | tr '[:upper:]' '[:lower:]'
}

# symphony_path_of <host/a/b> — the path part, empty for a host-only entry
# (which admits every project on that host).
symphony_path_of() {
  case "${1}" in */*) printf '%s' "${1#*/}" ;; *) printf '' ;; esac
}

# symphony_covered_by NEEDLE ENTRY... — prefix match on a path-segment
# boundary, so `a/b` admits `a/b` and `a/b/c` and refuses `a/b-evil`. A
# host-only (empty) entry covers everything.
symphony_covered_by() {
  local needle="${1}" entry; shift
  for entry in "$@"; do
    [ -n "${entry}" ] || return 0
    case "${needle}/" in "${entry}"/*) return 0 ;; esac
  done
  return 1
}

# symphony_allowlist_agreement WORKFLOW ALLOW_REMOTE_GIT GIT_REMOTE_ALLOWLIST
#   ALLOW_GITLAB_WRITE GITLAB_WRITE_PROJECTS — warns (never fatal) on a
# mismatch between the two allowlists, and cross-checks both against the
# tracker's own project (the one destination the workflow tells the agent to
# clone, so both gates have to admit it).
symphony_allowlist_agreement() {
  local workflow="$1" allow_remote_git="$2" git_allowlist="$3"
  local allow_gitlab_write="$4" write_projects="$5"
  local raw e remotes=() remote_paths=() writes=()

  raw="${git_allowlist}"
  for e in ${raw//,/ }; do
    e="$(symphony_norm_dest "${e}")"
    if [ -n "${e}" ]; then remotes+=("${e}"); fi
  done
  raw="${write_projects}"
  for e in ${raw//,/ }; do
    e="$(symphony_norm_dest "${e}")"
    if [ -n "${e}" ]; then writes+=("${e}"); fi
  done
  for e in ${remotes[@]+"${remotes[@]}"}; do
    if [ -n "${e}" ]; then remote_paths+=("$(symphony_path_of "${e}")"); fi
  done

  if [ "${allow_remote_git:-0}" = "1" ] && [ "${allow_gitlab_write:-0}" = "1" ] \
     && [ "${#remotes[@]}" -gt 0 ] && [ "${#writes[@]}" -gt 0 ]; then
    for e in "${writes[@]}"; do
      if ! symphony_covered_by "${e}" ${remote_paths[@]+"${remote_paths[@]}"}; then
        warn "  ${e} is in GITLAB_WRITE_PROJECTS but no GIT_REMOTE_ALLOWLIST entry covers it"
        warn "    the agent could open a merge request there and could not push the branch for it"
      fi
    done
    for e in ${remote_paths[@]+"${remote_paths[@]}"}; do
      [ -n "${e}" ] || continue
      if ! symphony_covered_by "${e}" ${writes[@]+"${writes[@]}"}; then
        warn "  ${e} is pushable per GIT_REMOTE_ALLOWLIST but not in GITLAB_WRITE_PROJECTS"
        warn "    the agent could push a branch there and could not open the merge request"
      fi
    done
  fi

  # The tracker's own project is the one destination that definitely matters.
  if [ "$(symphony_tracker_kind "$workflow")" != "gitlab" ]; then
    return 0
  fi
  local base project dest
  base="$(symphony_norm_dest "$(symphony_wf_scalar "$workflow" base_url)")"
  project="$(symphony_norm_dest "$(symphony_wf_scalar "$workflow" project_id)")"
  if [ -z "${base}" ] || [ -z "${project}" ]; then
    return 0
  fi
  # A numeric project_id is a valid GitLab reference but carries no path, so
  # there is nothing for an allowlist to be compared against.
  case "${project}" in
    *[!0-9]*) : ;;
    *) return 0 ;;
  esac
  dest="${base}/${project}"

  if [ "${allow_remote_git:-0}" = "1" ] && [ "${#remotes[@]}" -gt 0 ]; then
    if symphony_covered_by "${dest}" "${remotes[@]}"; then
      info "  tracker project ${dest} is git-reachable and API-writable"
    else
      warn "  tracker project ${dest} is not covered by GIT_REMOTE_ALLOWLIST"
      warn "    the workflow tells the agent to clone it and git-guard will refuse"
    fi
  fi
  if [ "${allow_gitlab_write:-0}" = "1" ] && [ "${#writes[@]}" -gt 0 ]; then
    if ! symphony_covered_by "${project}" "${writes[@]}"; then
      warn "  tracker project ${project} is not in GITLAB_WRITE_PROJECTS"
      warn "    the agent could not open a merge request against the project it is working"
    fi
  fi
  return 0
}

# --- egress derivation ----------------------------------------------------------
# symphony_http_proxy WORKFLOW — echo the proxy URL symphony should use, or
# empty. Not a user setting: derived from tracker.kind. Both of symphony's
# networks are internal: true (docker/docker-compose.symphony.yml), so squid
# — reached at the fixed compose service hostname `squid` — is the only
# possible way out either way; on the file queue this stays empty and the
# container has no route off-host at all. An explicit SYMPHONY_HTTP_PROXY in
# either symphony.env still wins. Also true whenever review is enabled
# (SYMPHONY_REVIEW_GITLAB_TOKEN set — see symphony_derive_settings's "Layer
# 5"): a review-only deployment may configure no tracker at all, yet the
# review controller's whole job is talking to GitLab, so it needs squid
# regardless of tracker.kind. Checked here (not gated behind a project name)
# because by the time this runs, review.env has already been loaded into the
# process environment — see symphony_derive_settings.
symphony_http_proxy() {
  local workflow="$1"
  if [ "$(symphony_tracker_kind "$workflow")" = "gitlab" ] || [ -n "${SYMPHONY_REVIEW_GITLAB_TOKEN:-}" ]; then
    printf '%s' "${SYMPHONY_HTTP_PROXY:-http://squid:3128}"
  else
    printf '%s' "${SYMPHONY_HTTP_PROXY:-}"
  fi
}

# --- review path helpers ---------------------------------------------------------
# The review controller's own per-project paths, following the exact
# relative-path convention lib/project.sh's project_*_file/project_*_dir
# helpers use (plain string concatenation against project_root_dir /
# project_config_dir, no filesystem access). Defined HERE rather than in
# lib/project.sh: review is additive to this slice, not a change to that
# file's job of naming the four pre-existing layers.

# symphony_review_env_file NAME — projects/<name>/review.env: the per-project,
# LAUNCHER-ONLY file for SYMPHONY_REVIEW_GITLAB_TOKEN (see
# projects/_example/review.env.example). Same containment as
# project_symphony_env_file: never named by any env_file: directive anywhere
# in this stack — see symphony_derive_settings's "Layer 5" below.
symphony_review_env_file() { printf '%s/review.env' "$(project_root_dir "$1")"; }

# symphony_review_workflow_file NAME — projects/<name>/config/REVIEW.md: the
# review controller's own trusted config + prompt (see
# templates/REVIEW.md.example), mounted read-only into /config alongside (or
# instead of) WORKFLOW.md. One level below review.env, same reasoning as
# project_workflow_file: the /config mount can never expose the file that
# might hold the review token.
symphony_review_workflow_file() { printf '%s/REVIEW.md' "$(project_config_dir "$1")"; }

# symphony_review_opencode_container_name / symphony_review_container_name
# NAME — container names matching docker/docker-compose.review.yml exactly,
# the review-side counterparts of lib/project.sh's
# project_opencode_container_name / project_container_name.
symphony_review_opencode_container_name() { printf 'symphony-%s-opencode-review' "$1"; }
symphony_review_container_name()          { printf 'symphony-%s-review' "$1"; }

# --- per-invocation settings -----------------------------------------------------
# symphony_derive_settings NAME — the four-layer env load plus the derived
# per-project paths. Sets, in the CALLER's scope (dynamic-scope "callee sets
# caller's local" — callers must declare these `local` first, same idiom
# lib/project.sh's resolve_project_port relies its callers on):
#   PROJECT_SLUG, PROJECT_ENV_FILE, COMPOSE,
#   SYM_CONFIG_DIR, SYM_QUEUE_DIR, SYM_WORKSPACES_DIR, SYM_ENV_FILE,
#   SYM_SYMPHONY_ENV_FILE, SYM_WORKFLOW, SYM_ALLOWLIST_DIR, SYM_CONTAINER
# and EXPORTS (real process environment, visible to every function called
# afterward regardless of scope) PROJECT_SLUG, PROJECT_ENV_FILE,
# SYMPHONY_CONFIG_PATH, SYMPHONY_QUEUE_PATH, SYMPHONY_WORKSPACES_PATH,
# SYMPHONY_REVIEW_STORE_PATH, SYMPHONY_REVIEW_WORKSPACES_PATH,
# SYMPHONY_HTTP_PROXY, and EXTRA_ALLOWLIST_PATH (only when the project ships
# its own allowlist.d/).
#
# A fifth, review-only layer sits after the four described below:
# projects/<name>/review.env — launcher-only, read the same way symphony.env
# is (load_env into the process environment, --env-file only on the compose
# invocation, never an env_file: directive) so SYMPHONY_REVIEW_GITLAB_TOKEN
# reaches a container only through the symphony-review service's own
# `environment:` block, exactly like SYMPHONY_GITLAB_TOKEN does for symphony.
# See docker/docker-compose.review.yml and projects/_example/review.env.example.
#
# The four layers, read in this exact order, last value wins:
#
#   .env                           shared,      agent-visible
#   symphony.env                   shared,      launcher-only
#     -> THEN derive+export the per-project paths
#   projects/<name>/.env           per-project, agent-visible
#   projects/<name>/symphony.env   per-project, launcher-only
#   -> then export PROJECT_ENV_FILE
#
# The derivation sits AFTER the shared files so a shared default cannot
# silently collapse two projects onto one queue (two orchestrators claiming
# one item is exactly what the rename(2)-is-atomic-within-one-filesystem
# claim assumes cannot happen — see the Project layout section of the
# README), and BEFORE the project's own files so an explicit per-project
# value still wins.
#
# Each `load_env` call below EXPORTS the file's keys into this process's real
# environment (see lib/core.sh) — which is also what lets symphony_preflight,
# called by every verb AFTER this function, read the fully-layered effective
# value of a setting (ALLOW_REMOTE_GIT, IMAGE_REGISTRY, ...) just by
# referencing the shell variable, with no re-reading of files required. The
# one deliberate exception is SYMPHONY_GITLAB_TOKEN: it is loaded here like
# any other key (so `check`'s effective-value checks can see it), but see
# the file header for why it must never be WRITTEN into an agent-visible file
# or handed to compose any other way than the symphony service's own
# `environment:` block.
#
# Does NOT create any projects/<name>/ directory itself — that is
# symphony_ensure_dirs's job, called only by verbs that actually start or
# write something (init/up/add), so check/status/logs/stop/down/config/
# projects stay side-effect-free with respect to the filesystem.
#
# ABSOLUTE paths for the four exported/compose-interpolated variables are
# built by plain string concatenation against $__SYM_DIR — NOT `cd`-resolved
# — so they are correct even before the directories exist on disk. That is
# required for `check`, which must create nothing.
symphony_derive_settings() {
  local name="$1"
  validate_project_name "$name"

  # Layer 1+2: shared files. Missing files are fine here — verbs that
  # require the root .env to exist (check/up/config) enforce that
  # themselves, with a message pointing at .env.example, before calling
  # this; read-only verbs (status/logs/stop/down) tolerate its absence.
  if [ -f "${__SYM_DIR}/${ENV_FILE}" ]; then load_env "${__SYM_DIR}/${ENV_FILE}"; fi
  if [ -f "${__SYM_DIR}/${SYMPHONY_ENV}" ]; then load_env "${__SYM_DIR}/${SYMPHONY_ENV}"; fi

  PROJECT_SLUG="$name"
  export PROJECT_SLUG

  local rel_config rel_queue rel_workspaces rel_workflow rel_allowlist rel_penv rel_psym
  local rel_review_store rel_review_workspaces rel_prev
  rel_config="$(project_config_dir "$name")"
  rel_queue="$(project_queue_dir "$name")"
  rel_workspaces="$(project_workspaces_dir "$name")"
  rel_workflow="$(project_workflow_file "$name")"
  rel_allowlist="$(project_allowlist_dir "$name")"
  rel_penv="$(project_env_file "$name")"
  rel_psym="$(project_symphony_env_file "$name")"
  # Review's own pair, siblings of queue/ and workspaces/ under
  # projects/<name>/, following the exact same "absolute, string-concatenated
  # against __SYM_DIR, never cd-resolved" rule as the four paths above — see
  # the ABSOLUTE-paths note at the end of this header.
  rel_review_store="$(project_root_dir "$name")/review-store"
  rel_review_workspaces="$(project_root_dir "$name")/review-workspaces"
  rel_prev="$(symphony_review_env_file "$name")"

  SYM_CONFIG_DIR="$rel_config"
  SYM_QUEUE_DIR="$rel_queue"
  SYM_WORKSPACES_DIR="$rel_workspaces"
  SYM_WORKFLOW="$rel_workflow"
  SYM_ALLOWLIST_DIR="$rel_allowlist"
  SYM_ENV_FILE="$rel_penv"
  SYM_SYMPHONY_ENV_FILE="$rel_psym"
  SYM_CONTAINER="$(project_container_name "$name")"

  export SYMPHONY_CONFIG_PATH SYMPHONY_QUEUE_PATH SYMPHONY_WORKSPACES_PATH
  export SYMPHONY_REVIEW_STORE_PATH SYMPHONY_REVIEW_WORKSPACES_PATH
  SYMPHONY_CONFIG_PATH="${__SYM_DIR}/${rel_config}"
  SYMPHONY_QUEUE_PATH="${__SYM_DIR}/${rel_queue}"
  SYMPHONY_WORKSPACES_PATH="${__SYM_DIR}/${rel_workspaces}"
  SYMPHONY_REVIEW_STORE_PATH="${__SYM_DIR}/${rel_review_store}"
  SYMPHONY_REVIEW_WORKSPACES_PATH="${__SYM_DIR}/${rel_review_workspaces}"

  # Layer 3+4: per-project files, read AFTER the derivation above so an
  # explicit per-project value can still win over the just-derived default,
  # but after the SHARED files so a shared default cannot alias every
  # project onto one queue (see the function header).
  if [ -f "${__SYM_DIR}/${rel_penv}" ]; then load_env "${__SYM_DIR}/${rel_penv}"; fi
  if [ -f "${__SYM_DIR}/${rel_psym}" ]; then load_env "${__SYM_DIR}/${rel_psym}"; fi

  export PROJECT_ENV_FILE
  PROJECT_ENV_FILE="${__SYM_DIR}/${rel_penv}"

  # Opt-in per-project egress surface: only set when the project actually
  # ships its own allowlist.d/, or this would mount an empty directory over
  # a shared allowlist that was working.
  if [ -d "${__SYM_DIR}/${rel_allowlist}" ]; then
    export EXTRA_ALLOWLIST_PATH="${__SYM_DIR}/${rel_allowlist}"
  fi

  # Layer 5: review.env, launcher-only, read AFTER symphony.env's per-project
  # layer for the same last-wins reasoning, and BEFORE symphony_http_proxy so
  # a review-enabled project's egress derivation can see the token that turns
  # review on. See the function header and lib/symphony.sh's file header.
  if [ -f "${__SYM_DIR}/${rel_prev}" ]; then load_env "${__SYM_DIR}/${rel_prev}"; fi

  export SYMPHONY_HTTP_PROXY
  SYMPHONY_HTTP_PROXY="$(symphony_http_proxy "$SYM_WORKFLOW")"

  # --- compose invocation ---
  # -p is not optional: without a distinct compose PROJECT NAME, `up` on one
  # stack treats another stack's containers as orphans to remove. Distinct
  # container names alone do not prevent that.
  COMPOSE=(docker compose --project-directory "$__SYM_DIR" --env-file "${ENV_FILE}")
  if [ -f "${__SYM_DIR}/${SYMPHONY_ENV}" ]; then
    COMPOSE+=(--env-file "${SYMPHONY_ENV}")
  fi
  if [ -f "${__SYM_DIR}/${rel_penv}" ]; then
    COMPOSE+=(--env-file "${rel_penv}")
  fi
  if [ -f "${__SYM_DIR}/${rel_psym}" ]; then
    COMPOSE+=(--env-file "${rel_psym}")
  fi
  if [ -f "${__SYM_DIR}/${rel_prev}" ]; then
    COMPOSE+=(--env-file "${rel_prev}")
  fi
  COMPOSE+=(-p "symphony-${name}")
  COMPOSE+=(-f "$__SYM_DIR/docker/docker-compose.yml" -f "$__SYM_DIR/docker/docker-compose.symphony.yml")
  # The review overlay is additive and opt-in, gated on the SAME signal
  # symphony_http_proxy and symphony_preflight use: SYMPHONY_REVIEW_GITLAB_TOKEN
  # present (from review.env, just loaded above). An ordinary
  # implementation-only project's resolved config never gains an
  # opencode-review / symphony-review service at all — see
  # docker/docker-compose.review.yml, a sibling of docker-compose.symphony.yml,
  # not a rewrite of the base.
  if [ -n "${SYMPHONY_REVIEW_GITLAB_TOKEN:-}" ]; then
    COMPOSE+=(-f "$__SYM_DIR/docker/docker-compose.review.yml")
  fi
}

# --- filesystem scaffolding -----------------------------------------------------

# symphony_ensure_dirs NAME — mkdir -p everything up/add/init need on disk.
# The six file_queue state dirs are created for tracker: file_queue AND for
# a project with no WORKFLOW.md yet (symphony_tracker_kind returns empty for
# a missing file, which is not "gitlab") — the latter is what lets `init`
# scaffold a usable file_queue layout before a WORKFLOW.md has even been
# written. Under tracker: gitlab they would just be a second, empty,
# meaningless board next to the real one (state lives in issue labels).
symphony_ensure_dirs() {
  local name="$1" workflow config_dir queue_dir workspaces_dir review_store_dir review_workspaces_dir d
  workflow="$(project_workflow_file "$name")"
  config_dir="$(project_config_dir "$name")"
  queue_dir="$(project_queue_dir "$name")"
  workspaces_dir="$(project_workspaces_dir "$name")"
  review_store_dir="$(project_root_dir "$name")/review-store"
  review_workspaces_dir="$(project_root_dir "$name")/review-workspaces"

  # review-store/ and review-workspaces/ are created unconditionally, exactly
  # like config/ and workspaces/ above: cheap on a project that never enables
  # review, and it means `up` never hands Docker a missing bind-mount source
  # to auto-create as root.
  mkdir -p "$config_dir" "$workspaces_dir" "$review_store_dir" "$review_workspaces_dir"
  if [ "$(symphony_tracker_kind "$workflow")" = "gitlab" ]; then
    return 0
  fi
  for d in todo in-progress review done failed cancelled; do
    mkdir -p "${queue_dir}/${d}"
  done
}

# --- status reporting ------------------------------------------------------------
# symphony_queue_status NAME — the board symphony is actually reading. Under
# tracker: gitlab, printing file counts from a leftover file-queue directory
# would be worse than printing nothing (it reads as pending work the
# orchestrator is not looking at), so this reports the tracker's
# project/board instead.
symphony_queue_status() {
  local name="$1" workflow queue_dir workspaces_dir container
  workflow="$(project_workflow_file "$name")"
  queue_dir="$(project_queue_dir "$name")"
  workspaces_dir="$(project_workspaces_dir "$name")"
  container="$(project_container_name "$name")"

  if [ "$(symphony_tracker_kind "$workflow")" = "gitlab" ]; then
    local base project
    base="$(symphony_wf_scalar "$workflow" base_url)"
    project="$(symphony_wf_scalar "$workflow" project_id)"
    info "tracker: gitlab — ${project:-<project_id unset>}"
    if [ -n "$base" ] && [ -n "$project" ]; then
      case "$project" in
        *[!0-9]*)
          info "  board: ${base%/}/${project}/-/issues?label_name[]=$(symphony_wf_scalar "$workflow" label_prefix)::todo" ;;
        *)
          info "  board: ${base%/} (project id $project)" ;;
      esac
    fi
    info "  queue state lives in the issues themselves — symphony logs $name"
    info "workspaces: $workspaces_dir"
  else
    local d n total=0
    info "queue: $queue_dir"
    for d in todo in-progress review failed done cancelled; do
      # -d first: `find` on a missing directory exits non-zero, and under
      # `set -o pipefail` that aborts the whole script. Reachable on any
      # queue whose state dirs have not been created yet — a freshly
      # scaffolded project, or `status` before the first `up`/`add`.
      if [ ! -d "${queue_dir}/${d}" ]; then
        printf '    %-12s -\n' "$d"
        continue
      fi
      n=$(find "${queue_dir}/${d}" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
      total=$((total + n))
      if [ "$n" -gt 0 ]; then printf '    %-12s %s\n' "$d" "$n"; else printf '    %-12s -\n' "$d"; fi
    done
    if [ "$total" -eq 0 ]; then
      info "queue is empty — add work with: symphony add $name \"...\""
    fi
  fi

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
    info "symphony: running"
  else
    info "symphony: NOT running"
  fi

  # Review status only for a project that actually has review configured
  # (review.env or REVIEW.md present on disk) — a plain implementation-only
  # project should never see a "symphony-review: NOT running" line it has no
  # way to start. A pure file-existence check (no symphony_derive_settings
  # call here — this function is read-only and cheap on purpose).
  if [ -f "$(symphony_review_env_file "$name")" ] || [ -f "$(symphony_review_workflow_file "$name")" ]; then
    local review_container
    review_container="$(symphony_review_container_name "$name")"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$review_container"; then
      info "symphony-review: running"
    else
      info "symphony-review: NOT running"
    fi
  fi
}

# --- preflight ---------------------------------------------------------------
# symphony_preflight NAME — everything here is a mistake that would
# otherwise surface as a confusing failure well after start-up, or worse, as
# an unattended agent doing something not intended. Prints passes/info via
# info(), warnings via warn(), and fatal problems via err(); returns 1
# (never exits/dies itself, so callers decide whether a failure should
# abort — check() and up() both do) iff any fatal problem was found.
#
# MUST be called AFTER symphony_derive_settings for the same NAME: this
# relies on the process environment already carrying the fully-layered
# effective values of every setting (ALLOW_REMOTE_GIT, GIT_REMOTE_ALLOWLIST,
# ALLOW_GITLAB_WRITE, GITLAB_WRITE_PROJECTS, SYMPHONY_GITLAB_TOKEN, GITLAB_PAT,
# IMAGE_REGISTRY, OPENCODE_INTERNAL_PORT) and the four absolute path exports
# (SYMPHONY_CONFIG_PATH/QUEUE_PATH/WORKSPACES_PATH, PROJECT_ENV_FILE) — see
# symphony_derive_settings's header for why those exports make that safe.
symphony_preflight() {
  local name="$1"
  local config_dir queue_dir workspaces_dir agent_env sym_env workflow
  config_dir="$(project_config_dir "$name")"
  queue_dir="$(project_queue_dir "$name")"
  workspaces_dir="$(project_workspaces_dir "$name")"
  agent_env="$(project_env_file "$name")"
  sym_env="$(project_symphony_env_file "$name")"
  workflow="$(project_workflow_file "$name")"

  local fatal=0 kind=""
  info "symphony preflight (project: ${name})"

  if [ ! -f "$workflow" ]; then
    if [ -n "${SYMPHONY_REVIEW_GITLAB_TOKEN:-}" ]; then
      # Review-only deployment (see templates/REVIEW.md.example and the
      # README's "The security model"): no implementation tracker configured
      # at all, so no WORKFLOW.md is expected — SYMPHONY_REVIEW_GITLAB_TOKEN
      # is what turns review mode on, checked below, independently of
      # tracker.kind. Not fatal.
      info "  no $workflow — review-only deployment, no implementation tracker configured"
    else
      err "  no $workflow"
      err "    cp templates/WORKFLOW.md.example $workflow          # file queue"
      err "    cp templates/WORKFLOW.gitlab.md.example $workflow   # GitLab issues"
      err "    (or: symphony init $name)"
      fatal=1
    fi
  else
    kind="$(symphony_tracker_kind "$workflow")"
    info "  workflow: $workflow (tracker: ${kind:-unknown})"
  fi

  # An AGENT-visible env file must not sit inside the directory mounted at
  # /config in the symphony container — that mount is symphony's, and
  # symphony is supposed to hold the Reporter token and nothing else. By
  # construction config_dir is a subdirectory of projects/<name>/, one level
  # below symphony.env, so this should never trigger in the generated
  # layout — it guards against a file dropped there by hand. Matched by
  # inode, not by name: the root .env or the project's own .env living
  # inside the default config dir would be the mistake this catches.
  if [ -d "$config_dir" ]; then
    local found found_agent_env
    for found in "$config_dir"/.env "$config_dir"/*.env; do
      [ -f "$found" ] || continue
      for found_agent_env in "${__SYM_DIR}/${ENV_FILE}" "$PROJECT_ENV_FILE"; do
        [ -f "$found_agent_env" ] || continue
        if [ "$found" -ef "$found_agent_env" ]; then
          err "  $found_agent_env is inside $config_dir, which is mounted into the symphony container"
          err "    symphony would be able to read the agent's credentials"
          fatal=1
        fi
      done
    done
  fi

  # symphony treats workspaces as disposable; it must never double as the
  # queue's state directory or the trusted config directory.
  if [ "$SYMPHONY_WORKSPACES_PATH" = "$SYMPHONY_QUEUE_PATH" ] || [ "$SYMPHONY_WORKSPACES_PATH" = "$SYMPHONY_CONFIG_PATH" ]; then
    err "  SYMPHONY_WORKSPACES_PATH is the same directory as the queue or config path ($SYMPHONY_WORKSPACES_PATH)"
    err "    symphony treats workspaces as disposable — point it somewhere else"
    fatal=1
  fi

  # Some .env readers keep an inline `# comment` as part of the value.
  # Checked only for the two LAUNCHER-only files: nothing else reads them
  # (the agent-visible files get a different check, below), so this is the
  # only place a mistake here would ever be caught.
  local launcher_file inline
  for launcher_file in "$SYMPHONY_ENV" "$sym_env"; do
    [ -f "$launcher_file" ] || continue
    if inline="$(grep -nE '^[A-Za-z_][A-Za-z0-9_]*=[^#]*[[:space:]]#' "$launcher_file" 2>/dev/null)" && [ -n "$inline" ]; then
      err "  inline '#' comments in $launcher_file — move them to their own lines:"
      printf '      %s\n' "$inline" >&2
      fatal=1
    fi
  done

  local sym_token="${SYMPHONY_GITLAB_TOKEN:-}"
  case "$kind" in
    gitlab)
      if [ -n "$sym_token" ]; then
        info "  SYMPHONY_GITLAB_TOKEN set (should be a Reporter project token)"
      else
        err "  tracker is gitlab but SYMPHONY_GITLAB_TOKEN is empty"
        err "    set it in $sym_env — a Reporter token, never the agent's Developer token (GITLAB_PAT)"
        fatal=1
      fi
      local agent_token="${GITLAB_PAT:-}"
      # The other half of the two-token split, and the one nothing checked. A
      # gitlab-tracker run is branch-and-merge-request shaped: the orchestrator
      # creates an EMPTY directory and the clone is the agent's first step, so an
      # agent with no credential cannot even begin. That failure is invisible
      # until late and reads as nothing at all — the issue moves to In Review
      # having pushed nothing, and the only clue is six minutes of wall clock.
      # Refusing here is symmetric with the orchestrator-token check above, and
      # it costs a second instead of a run.
      if [ -z "$agent_token" ]; then
        err "  tracker is gitlab but GITLAB_PAT is empty — the agent cannot clone or push"
        err "    set it in $(project_env_file "$name") — a Developer token, scoped to this"
        err "    project, and NOT the orchestrator's Reporter token (SYMPHONY_GITLAB_TOKEN)"
        err "    it must be per-project: this file is the only layer that reaches the agent"
        fatal=1
      else
        info "  GITLAB_PAT set (should be a Developer project token)"
      fi
      if [ -n "$sym_token" ] && [ -n "$agent_token" ] && [ "$sym_token" = "$agent_token" ]; then
        # Fatal, not a warning: with one credential doing both jobs there is
        # no containment left to warn about. Either it is Reporter, in which
        # case the agent cannot push and every run fails late and
        # confusingly; or it is Developer, in which case the ORCHESTRATOR can
        # push code and a prompt-injected agent holding the same credential
        # can relabel its own issue — marking its own work reviewed, or
        # queueing itself more. The role, not the `api` scope, is what
        # constrains either side (see the README's "The token's scope is the
        # boundary").
        #
        # Checked here rather than only in cmd_check's resolved-config
        # cross-check so the verdict does not depend on whether docker happens
        # to be installed.
        err "  SYMPHONY_GITLAB_TOKEN and GITLAB_PAT are the same token"
        err "    the two-token split IS the containment: mint a Reporter token for the"
        err "    orchestrator ($sym_env) and a separate Developer token for the agent"
        fatal=1
      fi
      # A Reporter token inherited from the shared root symphony.env reaches
      # ONE project — whichever it was minted for. A second project using it
      # either 404s (confusing), or, if it happens to be a group token, gets
      # more reach than its own project needs. The per-project token is what
      # keeps the boundary per-project.
      if [ -n "$sym_token" ] && [ -f "$SYMPHONY_ENV" ]; then
        local own_token shared_token
        own_token="$(env_file_get "$sym_env" SYMPHONY_GITLAB_TOKEN)"
        shared_token="$(env_file_get "$SYMPHONY_ENV" SYMPHONY_GITLAB_TOKEN)"
        if [ -z "$own_token" ] && [ -n "$shared_token" ]; then
          warn "  SYMPHONY_GITLAB_TOKEN comes from the shared $SYMPHONY_ENV"
          warn "    a project access token reaches one project — give $name its own in $sym_env"
        fi
      fi
      ;;
    file_queue|"")
      if [ -n "$sym_token" ]; then
        warn "  SYMPHONY_GITLAB_TOKEN is set but the tracker is the file queue — it is unused"
      else
        info "  file queue: symphony holds no credentials"
      fi
      ;;
  esac

  # --- the review token (the THIRD credential) ---------------------------------
  # SYMPHONY_REVIEW_GITLAB_TOKEN is the review controller's own Reporter
  # token — see README's "The security model" and
  # projects/_example/review.env.example. Its PRESENCE is what turns review
  # mode on for this project, deliberately independent of tracker.kind (a
  # review-only deployment may configure no tracker at all — see the
  # WORKFLOW.md check above). Same equality logic, same reasoning, and the
  # same style as the SYMPHONY_GITLAB_TOKEN/GITLAB_PAT check above: with any
  # two of the three tokens equal, one credential is doing two jobs and there
  # is no containment left to warn about.
  local review_token="${SYMPHONY_REVIEW_GITLAB_TOKEN:-}"
  local review_workflow
  review_workflow="$(symphony_review_workflow_file "$name")"
  if [ -n "$review_token" ]; then
    if [ -n "$sym_token" ] && [ "$review_token" = "$sym_token" ]; then
      err "  SYMPHONY_REVIEW_GITLAB_TOKEN and SYMPHONY_GITLAB_TOKEN are the same token"
      err "    revocability is the point: mint the review controller its own Reporter"
      err "    token, separate from the implementation orchestrator's, in $(symphony_review_env_file "$name")"
      fatal=1
    fi
    local agent_token_rv="${GITLAB_PAT:-}"
    if [ -n "$agent_token_rv" ] && [ "$review_token" = "$agent_token_rv" ]; then
      err "  SYMPHONY_REVIEW_GITLAB_TOKEN and GITLAB_PAT are the same token"
      err "    the reviewer must never hold a token that can push — mint it its own"
      err "    Reporter token, separate from the agent's Developer token (GITLAB_PAT)"
      fatal=1
    fi

    if [ ! -f "$review_workflow" ]; then
      err "  no $review_workflow"
      err "    cp templates/REVIEW.md.example $review_workflow"
      fatal=1
    else
      info "  review: $review_workflow"
    fi
  else
    info "  no SYMPHONY_REVIEW_GITLAB_TOKEN set — review is off for this project"
  fi

  # SYMPHONY_* keys belong in a launcher-only file. Both agent-visible files
  # get this check because docker-compose.yml hands them to the AGENT's
  # container wholesale (env_file:), so a tracker token left in either is a
  # token the agent can read.
  local agent_file stale
  for agent_file in "$ENV_FILE" "$agent_env"; do
    [ -f "${__SYM_DIR}/${agent_file}" ] || continue
    stale="$(grep -oE '^SYMPHONY_[A-Z_]+' "${__SYM_DIR}/${agent_file}" 2>/dev/null | sort -u | tr '\n' ' ')" || true
    if [ -n "$stale" ]; then
      warn "  SYMPHONY_* key(s) in $agent_file: $stale"
      warn "    move them to $sym_env — $agent_file is handed to the agent's container"
    fi
  done

  local allow_remote_git="${ALLOW_REMOTE_GIT:-0}" git_allowlist="${GIT_REMOTE_ALLOWLIST:-}"
  local allow_gitlab_write="${ALLOW_GITLAB_WRITE:-0}" write_projects="${GITLAB_WRITE_PROJECTS:-}"

  if [ "$allow_remote_git" = "1" ]; then
    if [ -n "$git_allowlist" ]; then
      info "  remote git ON, restricted to: $git_allowlist"
    else
      warn "  remote git is ON and GIT_REMOTE_ALLOWLIST is EMPTY"
      warn "    an unattended agent may push to any remote its token can reach"
    fi
  else
    info "  remote git OFF — the agent can commit but cannot push (fine for early runs)"
  fi

  if [ "$allow_gitlab_write" = "1" ] && [ -z "$write_projects" ]; then
    warn "  ALLOW_GITLAB_WRITE=1 with no GITLAB_WRITE_PROJECTS — writes are not project-limited"
  fi

  if [ -f "$workflow" ]; then
    symphony_allowlist_agreement "$workflow" "$allow_remote_git" "$git_allowlist" \
      "$allow_gitlab_write" "$write_projects"
  fi

  # Concurrency/turns come from WORKFLOW.md; surface them since they are the
  # two numbers most worth keeping small while a deployment is still new.
  if [ -f "$workflow" ]; then
    local turns conc
    turns="$(sed -n 's/^[[:space:]]*max_turns:[[:space:]]*\([0-9]*\).*/\1/p' "$workflow" | head -1)"
    conc="$(sed -n 's/^[[:space:]]*max_concurrent_agents:[[:space:]]*\([0-9]*\).*/\1/p' "$workflow" | head -1)"
    info "  max_turns=${turns:-?}  max_concurrent_agents=${conc:-?}"
    if [ -n "$conc" ] && [ "$conc" -gt 1 ] 2>/dev/null; then
      warn "  more than one agent at a time — consider 1 until you trust a full run"
    fi
  fi

  # --- newer failure modes, each documented in docs/TROUBLESHOOTING.md ---

  if [ -f "$workflow" ]; then
    # Without a completion_marker the run always uses every turn: symphony
    # owns the item's active/terminal state and does not move it until the
    # run ends, so "is it still active?" is true on every turn, and
    # symphony-queue v0.5.0 refuses to start without one being configured
    # AND present in the prompt.
    local marker body_text
    marker="$(symphony_wf_scalar "$workflow" completion_marker)"
    if [ -n "$marker" ]; then
      body_text="$(symphony_wf_body "$workflow")"
      if ! printf '%s\n' "$body_text" | grep -qF -- "$marker"; then
        warn "  agent.completion_marker is '$marker' but that string never appears in the prompt body"
        warn "    without the agent being asked for it, every run burns its full turn budget"
      fi
    fi

    # A clone in this hook runs in the SYMPHONY container, which deliberately
    # holds no repository credential (only the Reporter token, or nothing at
    # all on file_queue).
    local after_create
    after_create="$(symphony_wf_scalar "$workflow" after_create)"
    if [ -n "$after_create" ]; then
      warn "  hooks.after_create is non-empty: $after_create"
      warn "    a clone there forces a repository credential into the container that deliberately has none"
    fi

    # The orchestrator dials opencode.server_url; the entrypoint's readiness
    # wait uses OPENCODE_INTERNAL_PORT (docker/docker-compose.symphony.yml
    # SYMPHONY_OPENCODE_URL). A mismatch means the orchestrator is dialing
    # somewhere the entrypoint never actually listens on.
    local server_url expected_url
    server_url="$(symphony_wf_scalar "$workflow" server_url)"
    expected_url="http://opencode:${OPENCODE_INTERNAL_PORT:-4096}"
    if [ -n "$server_url" ] && [ "$server_url" != "$expected_url" ]; then
      warn "  opencode.server_url is '$server_url' but the entrypoint waits on '$expected_url'"
      warn "    the orchestrator dials the former; a mismatch means it never sees opencode come up"
    fi

    if [ "$kind" = "gitlab" ]; then
      # Two lines duplicate tracker.project_id on purpose (see the README's
      # "The agent clones its own workspace") — the clone URL has to come
      # from somewhere the agent can trust, and the prompt body is the only
      # place that is safe. This check is what cross-checks the duplication.
      local project_id
      project_id="$(symphony_wf_scalar "$workflow" project_id)"
      if [ -n "$project_id" ]; then
        body_text="$(symphony_wf_body "$workflow")"
        if ! printf '%s\n' "$body_text" | grep -qF -- "$project_id"; then
          warn "  the clone URL in the prompt body does not mention tracker.project_id ($project_id)"
          warn "    edit the URL in \"First: clone the project\" to match, or the two will drift"
        fi
      fi

      # `TypeError: fetch failed` — the most likely first failure on a fresh
      # gitlab tracker (docs/TROUBLESHOOTING.md) — is often squid refusing
      # the tracker host outright. Guarded (-d first) per the same
      # find/glob-on-missing-directory hazard documented elsewhere in this
      # file.
      local base_url host allow_dir found_host=0 f
      base_url="$(symphony_wf_scalar "$workflow" base_url)"
      host="$(symphony_norm_dest "$base_url")"
      host="${host%%/*}"
      allow_dir="${EXTRA_ALLOWLIST_PATH:-${__SYM_DIR}/extra-allowlist.d}"
      if [ -n "$host" ] && [ -d "$allow_dir" ]; then
        for f in "$allow_dir"/*.conf; do
          [ -f "$f" ] || continue
          if grep -qF -- "$host" "$f" 2>/dev/null; then found_host=1; fi
        done
        if [ "$found_host" -eq 0 ]; then
          warn "  tracker host '$host' is not mentioned by any *.conf under $allow_dir"
          warn "    this is the 'TypeError: fetch failed' failure — see docs/TROUBLESHOOTING.md"
        fi
      fi

      # stall_timeout_ms currently measures a RUN, not a stall (see
      # docs/TROUBLESHOOTING.md) — too short for anything that clones a
      # repository.
      local stall
      stall="$(symphony_wf_scalar "$workflow" stall_timeout_ms)"
      case "$stall" in
        ''|*[!0-9]*) : ;;
        *)
          if [ "$stall" -lt 600000 ]; then
            warn "  stall_timeout_ms is ${stall}ms (< 600000) — it measures run time, not stalls, currently"
            warn "    too short for anything that clones a repo; raise it before a real run"
          fi ;;
      esac
    fi
  fi

  case "${IMAGE_REGISTRY:-}" in
    *CHANGEME*|*.example*)
      warn "  IMAGE_REGISTRY looks like a placeholder (${IMAGE_REGISTRY})"
      warn "    edit .env and set your real registry path" ;;
  esac

  # rename(2) is atomic only WITHIN one filesystem, which is the entire
  # atomic-claim argument (see the README's "Project layout"). Only checked
  # for directories that already exist — a fresh `init` has created nothing
  # yet — and skipped cleanly without `stat`.
  if { [ "$kind" = "file_queue" ] || [ -z "$kind" ]; } && command -v stat >/dev/null 2>&1; then
    local qd dev first_dev="" mismatch=0 d
    for d in todo in-progress review done failed cancelled; do
      qd="${queue_dir}/${d}"
      [ -d "$qd" ] || continue
      dev="$(stat -c %d "$qd" 2>/dev/null || true)"
      [ -n "$dev" ] || continue
      if [ -z "$first_dev" ]; then
        first_dev="$dev"
      elif [ "$dev" != "$first_dev" ]; then
        mismatch=1
      fi
    done
    if [ "$mismatch" -eq 1 ]; then
      warn "  the six queue state directories are not all on one filesystem"
      warn "    rename(2) is atomic only within one filesystem, and the whole claim argument rests on it"
    fi
  fi

  if [ "$fatal" -ne 0 ]; then
    err "preflight failed."
    return 1
  fi
  return 0
}
