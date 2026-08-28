# Shared helpers for the symphony bats suite.
#
# Three test styles use these:
#   * unit    — `source ./symphony` (the source-guard makes that safe) and
#               call a pure helper directly.
#   * cli     — run a sandboxed COPY of ./symphony as a subprocess, with a
#               fake `docker` on PATH, and assert on its output / side
#               effects.
#   * compose — resolve the sandboxed stack with the REAL `docker compose
#               config` (no daemon needed) and assert on the resolved YAML.

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$COMMON_DIR/.." && pwd)"
FAKE_BIN="$COMMON_DIR/fake-bin"

# make_sandbox — copy the launcher into an isolated temp dir so .env/projects/
# writes never touch the real repo, and put the fake docker first on PATH.
# Sets $SANDBOX and exports $FAKE_DOCKER_LOG (truncated).
make_sandbox() {
  SANDBOX="$BATS_TEST_TMPDIR/launcher"
  mkdir -p "$SANDBOX"
  cp "$REPO_ROOT/symphony" "$SANDBOX/"
  cp -r "$REPO_ROOT/lib" "$SANDBOX/"
  cp -r "$REPO_ROOT/templates" "$SANDBOX/"
  cp "$REPO_ROOT/.env.example" "$SANDBOX/"
  mkdir -p "$SANDBOX/docker"
  cp "$REPO_ROOT"/docker/docker-compose*.yml "$SANDBOX/docker/" 2>/dev/null || true
  mkdir -p "$SANDBOX/projects"
  cp -r "$REPO_ROOT/projects/_example" "$SANDBOX/projects/"
  mkdir -p "$SANDBOX/extra-allowlist.d"
  cp -r "$REPO_ROOT/extra-allowlist.d"/*.conf "$SANDBOX/extra-allowlist.d/" 2>/dev/null || true

  export FAKE_DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
  : > "$FAKE_DOCKER_LOG"
  export PATH="$FAKE_BIN:$PATH"
}

# seed_env — pre-create $SANDBOX/.env from the shipped example, with a
# non-placeholder registry so the placeholder warning stays quiet.
seed_env() {
  cp "$SANDBOX/.env.example" "$SANDBOX/.env"
  sed -i 's|^IMAGE_REGISTRY=.*|IMAGE_REGISTRY=reg.test.local/opencode|' "$SANDBOX/.env"
}

# make_project NAME [file_queue|gitlab] [project_id] — write a minimal but
# valid projects/<name>/config/WORKFLOW.md (front matter only — these tests
# never exercise the prompt body) plus projects/<name>/{config,workspaces}.
# Deliberately does NOT create the six queue/ state directories — several
# tests rely on them not existing yet (status before the first up/add).
make_project() {
  local name="$1" kind="${2:-file_queue}" project_id="${3:-mygroup/myproject}"
  local dir="$SANDBOX/projects/$name/config"
  mkdir -p "$dir" "$SANDBOX/projects/$name/workspaces"
  if [ "$kind" = "gitlab" ]; then
    cat > "$dir/WORKFLOW.md" <<EOF
---
tracker:
  kind: gitlab
  base_url: https://gitlab.example.com
  project_id: ${project_id}
  label_prefix: symphony
agent:
  max_turns: 3
  max_concurrent_agents: 1
---
body
EOF
  else
    cat > "$dir/WORKFLOW.md" <<'EOF'
---
tracker:
  kind: file_queue
agent:
  max_turns: 3
  max_concurrent_agents: 1
---
body
EOF
  fi
}

# run_launcher [args...] — run the sandboxed ./symphony as a subprocess.
run_launcher() {
  run bash "$SANDBOX/symphony" "$@"
}

# docker_log — print the recorded fake-docker call log.
docker_log() { cat "$FAKE_DOCKER_LOG"; }

# resolve_compose_config NAME [--publish] — run the SAME derivation every
# real verb runs (symphony_derive_settings, exactly as cmd_config/cmd_up call
# it — not a re-implementation of it), then the REAL `docker compose ...
# config` for NAME's fully resolved stack. Writes the resolved YAML (stdout
# + stderr combined) to a fresh file and sets $COMPOSE_CONFIG_OUT to its
# path; returns compose's exit code. Requires $SANDBOX/.env to already exist
# (seed_env) — symphony_derive_settings always puts --env-file "$ENV_FILE" on
# the compose invocation, existing or not, same as every real verb assumes.
resolve_compose_config() {
  local name="$1"; shift
  local publish=0
  case "${1:-}" in --publish) publish=1; shift ;; esac
  local out="$BATS_TEST_TMPDIR/resolved-${name}-${publish}-${RANDOM}.yml"
  ( cd "$SANDBOX" && NAME="$name" PUBLISH="$publish" bash -c '
      set -eu
      # Sourcing ./symphony is side-effect-free (main() only runs when the
      # file is executed directly — the source-guard at its own end), so this
      # pulls in symphony_derive_settings and everything it depends on
      # exactly as a real verb would load it.
      source ./symphony
      PROJECT_SLUG="" PROJECT_ENV_FILE="" COMPOSE=()
      SYM_CONFIG_DIR="" SYM_QUEUE_DIR="" SYM_WORKSPACES_DIR="" SYM_ENV_FILE=""
      SYM_SYMPHONY_ENV_FILE="" SYM_WORKFLOW="" SYM_ALLOWLIST_DIR="" SYM_CONTAINER=""
      symphony_derive_settings "$NAME"
      if [ "$PUBLISH" = "1" ]; then
        export OPENCODE_PORT="${OPENCODE_PORT:-4096}"
        COMPOSE+=(-f "docker/docker-compose.publish.yml")
      fi
      "${COMPOSE[@]}" config
    ' ) > "$out" 2>&1
  local rc=$?
  COMPOSE_CONFIG_OUT="$out"
  return "$rc"
}

# resolve_or_fail NAME [--publish] — resolve_compose_config, failing the
# CURRENT test immediately (dumping the resolved output for debugging) if
# compose itself failed to resolve the stack, so a resolution failure reads
# as a clear compose error rather than a confusing downstream assertion
# failure. Sets $COMPOSE_CONFIG_OUT exactly like resolve_compose_config.
resolve_or_fail() {
  resolve_compose_config "$@"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "docker compose config failed to resolve (rc=$rc):" >&2
    cat "$COMPOSE_CONFIG_OUT" >&2
    return 1
  fi
  return 0
}

# service_block FILE SERVICE — print the named top-level service's block from
# a resolved `docker compose config` YAML: the `  <service>:` line up to (not
# including) the next 2-space-indented key or a 0-indent top-level key.
# Mirrors the isolation lib/commands.sh's cmd_check itself uses for the same
# purpose (finding the opencode service's own block to cross-check a token
# against), generalized to any service name.
service_block() {
  local file="$1" svc="$2"
  awk -v want="  ${svc}:" '
    $0 == want { grab=1; print; next }
    grab && /^(  [A-Za-z]|[A-Za-z])/ { grab=0 }
    grab { print }
  ' "$file"
}

# network_block FILE NETWORK — print the named top-level network's own
# definition block from the `networks:` section (name/driver/internal), NOT
# any service's `networks:` list of memberships (those are indented deeper —
# 6 spaces vs. this section's 2 — so the exact "  <network>:" match below
# only ever hits the definition).
network_block() {
  local file="$1" net="$2"
  awk -v want="  ${net}:" '
    $0 == want { grab=1; print; next }
    grab && /^(  [A-Za-z]|[A-Za-z])/ { grab=0 }
    grab { print }
  ' "$file"
}

# service_networks BLOCK_TEXT — given a service block (as text, e.g. from
# service_block), print the name of every network the service is a member
# of, one per line. `docker compose config` renders a service's own
# `networks:` key as a nested map (`      <net>: null`, 6-space indent, one
# level deeper than the service's other 4-space keys) — the same list ->
# map rendering `mount_source` above already relies on for volumes. Anchored
# on the exact 4-space `    networks:` line so a same-named top-level
# section elsewhere in the file (there is none inside one service block, but
# nothing here assumes that) can never be mistaken for it.
service_networks() {
  local block="$1"
  printf '%s\n' "$block" | awk '
    /^    networks:$/ { grab=1; next }
    grab && /^      [A-Za-z0-9_.-]+:/ { n=$0; sub(/^      /, "", n); sub(/:.*/, "", n); print n; next }
    grab { grab=0 }
  '
}

# mount_source BLOCK_TEXT TARGET — given a service block (as text, e.g. from
# service_block) and a mount target path (e.g. "/workspaces"), print the
# `source:` value of the (bind or volume) mount whose `target:` matches
# exactly. Relies on `docker compose config`'s stable long-syntax volume
# rendering: type, then source, then target, one per line, in that order.
mount_source() {
  local block="$1" target="$2"
  printf '%s\n' "$block" | awk -v tgt="$target" '
    /^ *- type: / { src="" }
    /^ *source: / { s=$0; sub(/^ *source: */, "", s); src=s }
    /^ *target: / { t=$0; sub(/^ *target: */, "", t); if (t == tgt) print src }
  '
}

# have_docker_compose — 0 iff `docker compose version` actually works here
# (no daemon required). compose.bats skips cleanly when it doesn't, so the
# rest of the suite still runs on a box with no docker at all. Deliberately
# bypasses $FAKE_BIN (which is normally ahead of it on $PATH once
# make_sandbox has run, and whose own `docker compose version` always exits
# 0 regardless of whether a real docker exists) so this reflects the HOST's
# real capability, exactly like the fake's own `compose config` delegation
# does.
have_docker_compose() {
  local dir
  local IFS=:
  for dir in $PATH; do
    [ -n "$dir" ] || continue
    [ "$dir" = "$FAKE_BIN" ] && continue
    if [ -x "$dir/docker" ]; then
      "$dir/docker" compose version >/dev/null 2>&1
      return $?
    fi
  done
  return 1
}
