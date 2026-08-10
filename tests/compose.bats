#!/usr/bin/env bats
#
# The most important file in this suite. These resolve the REAL stack with
# the REAL `docker compose ... config` — no daemon needed for that — and
# assert on what it actually produced, not on what lib/*.sh merely intends.
# Skips cleanly (not a failure) when `docker compose` itself isn't usable
# here, so the rest of the suite still runs on a box with no docker at all.
# See tests/README.md for why this never boots the stack.

setup() {
  load common
  make_sandbox
  seed_env
  if ! have_docker_compose; then
    skip "docker compose is not available in this environment"
  fi
}

# --- 1. THE token-isolation invariant ----------------------------------------
# The single most important guarantee in this whole launcher (see
# lib/symphony.sh's header): SYMPHONY_GITLAB_TOKEN reaches compose ONLY via
# --env-file interpolation and lands inside a container ONLY through the
# symphony service's own `environment:` block. A distinctive value in each of
# the two tokens' source files must show up exactly where it belongs and
# nowhere else in the resolved stack.

@test "THE TOKEN-ISOLATION INVARIANT: SYMPHONY_GITLAB_TOKEN appears exactly once, only inside the symphony service, never inside opencode" {
  make_project my-svc gitlab
  printf 'SYMPHONY_GITLAB_TOKEN=REPORTER-TOKEN-DISTINCT-VALUE-99999\n' > "$SANDBOX/projects/my-svc/symphony.env"
  printf 'GITLAB_PAT=AGENT-PAT-DISTINCT-VALUE-77777\n' > "$SANDBOX/projects/my-svc/.env"

  resolve_or_fail my-svc
  local out="$COMPOSE_CONFIG_OUT"

  local count
  count="$(grep -c "REPORTER-TOKEN-DISTINCT-VALUE-99999" "$out")"
  if [ "$count" -ne 1 ]; then
    echo "INVARIANT BROKEN: SYMPHONY_GITLAB_TOKEN's value appears $count time(s) in the resolved stack (want exactly 1)." >&2
    echo "This is the containment lib/symphony.sh's header describes — the Reporter token must reach compose ONLY via" >&2
    echo "--env-file and land in a container ONLY through the symphony service's own environment: block." >&2
    false
  fi

  local sym_block opencode_block
  sym_block="$(service_block "$out" symphony)"
  opencode_block="$(service_block "$out" opencode)"

  if [[ "$sym_block" != *"REPORTER-TOKEN-DISTINCT-VALUE-99999"* ]]; then
    echo "INVARIANT BROKEN: the token's one occurrence is NOT inside the symphony service block." >&2
    false
  fi
  if [[ "$opencode_block" == *"REPORTER-TOKEN-DISTINCT-VALUE-99999"* ]]; then
    echo "INVARIANT BROKEN: SYMPHONY_GITLAB_TOKEN leaked into the opencode service's resolved config — the agent's" >&2
    echo "container must never be able to read the orchestrator's Reporter token." >&2
    false
  fi

  # The agent's own Developer token (GITLAB_PAT) is expected in opencode,
  # never in symphony — the converse of the same containment.
  [[ "$opencode_block" == *"AGENT-PAT-DISTINCT-VALUE-77777"* ]]
  [[ "$sym_block" != *"AGENT-PAT-DISTINCT-VALUE-77777"* ]]
}

# --- 2. /workspace: a volume, never a bind -----------------------------------

@test "/workspace resolves to a named VOLUME, never a bind mount, anywhere in the stack" {
  make_project my-svc file_queue
  resolve_or_fail my-svc
  local out="$COMPOSE_CONFIG_OUT"

  # docker-compose.yml's header: no ${REPO_PATH}:/workspace bind may ever
  # exist here — an unattended agent must never get read-write access to a
  # developer's real checkout. Anchored on "$" so "/workspaces" (a different,
  # legitimately-bound path) never matches.
  local matches
  matches="$(awk '/^ *- type: /{t=$0} /target: \/workspace$/{print t}' "$out")"
  [ -n "$matches" ] || { echo "no /workspace mount found at all in the resolved stack" >&2; false; }
  [[ "$matches" != *"bind"* ]] || { echo "/workspace is bound from the HOST — see docker-compose.yml's header" >&2; false; }
  [[ "$matches" == *"volume"* ]]
}

# --- 3. /workspaces: bound to the project's own dir, in both services -------

@test "/workspaces is bound to the project's own workspaces dir in BOTH opencode and symphony, at the same host path" {
  make_project my-svc file_queue
  resolve_or_fail my-svc
  local out="$COMPOSE_CONFIG_OUT"

  local oc_block sym_block oc_src sym_src expected
  oc_block="$(service_block "$out" opencode)"
  sym_block="$(service_block "$out" symphony)"
  oc_src="$(mount_source "$oc_block" /workspaces)"
  sym_src="$(mount_source "$sym_block" /workspaces)"
  expected="$SANDBOX/projects/my-svc/workspaces"

  [ "$oc_src" = "$expected" ]
  [ "$sym_src" = "$expected" ]
  [ "$oc_src" = "$sym_src" ]
}

# --- 4. /config: read-only into symphony -------------------------------------

@test "/config is mounted read-only into the symphony service" {
  make_project my-svc file_queue
  resolve_or_fail my-svc
  local sym_block; sym_block="$(service_block "$COMPOSE_CONFIG_OUT" symphony)"

  local match
  match="$(printf '%s\n' "$sym_block" | grep -A2 'target: /config$')"
  [ -n "$match" ] || { echo "no /config mount found in the symphony service" >&2; false; }
  [[ "$match" == *"read_only: true"* ]]
}

# --- 5. port publishing: opt-in, loopback-only, exactly two ------------------

@test "the default stack publishes NO host ports at all" {
  make_project my-svc file_queue
  resolve_or_fail my-svc
  ! grep -q '^ *ports:' "$COMPOSE_CONFIG_OUT"
}

@test "the --publish overlay publishes exactly two ports, both bound to 127.0.0.1" {
  make_project my-svc file_queue
  resolve_or_fail my-svc --publish
  local out="$COMPOSE_CONFIG_OUT"

  local loopback_count total_ports_blocks
  loopback_count="$(grep -c 'host_ip: 127.0.0.1' "$out")"
  [ "$loopback_count" -eq 2 ]
  ! grep -q 'host_ip: 0.0.0.0' "$out"

  total_ports_blocks="$(grep -c '^ *ports:' "$out")"
  [ "$total_ports_blocks" -eq 1 ]
}

# --- 6. internal networks -----------------------------------------------------

@test "both oc_internal and oc_proxy are internal: true" {
  make_project my-svc file_queue
  resolve_or_fail my-svc
  local out="$COMPOSE_CONFIG_OUT"

  local oc_internal_block oc_proxy_block
  oc_internal_block="$(network_block "$out" oc_internal)"
  oc_proxy_block="$(network_block "$out" oc_proxy)"
  [[ "$oc_internal_block" == *"internal: true"* ]]
  [[ "$oc_proxy_block" == *"internal: true"* ]]
}

# --- 7. pull-only, and every image resolves off IMAGE_REGISTRY --------------

@test "no build: key at the start of a line in any docker/*.yml (pull-only stack)" {
  # The substring "build:" legitimately appears inside this file's own
  # explanatory prose ("There is no build: block here..."); a real YAML key
  # sits at the start of a line (module indentation), so anchor on that.
  run bash -c "grep -rnE '^[[:space:]]*build:' '$SANDBOX/docker'/*.yml"
  [ "$status" -eq 1 ]
}

@test "all three images resolve to \${IMAGE_REGISTRY}, -squid and -symphony, with the same tag" {
  make_project my-svc file_queue
  resolve_or_fail my-svc
  local out="$COMPOSE_CONFIG_OUT"

  grep -q '^    image: reg\.test\.local/opencode:latest$' "$out"
  grep -q '^    image: reg\.test\.local/opencode-squid:latest$' "$out"
  grep -q '^    image: reg\.test\.local/opencode-symphony:latest$' "$out"
}

# --- 8. egress derived from tracker.kind -------------------------------------

@test "egress is derived from tracker.kind: HTTP_PROXY is empty for file_queue and http://squid:3128 for gitlab, in the resolved symphony service" {
  make_project fq file_queue
  make_project gl gitlab

  resolve_or_fail fq
  local fq_sym; fq_sym="$(service_block "$COMPOSE_CONFIG_OUT" symphony)"
  resolve_or_fail gl
  local gl_sym; gl_sym="$(service_block "$COMPOSE_CONFIG_OUT" symphony)"

  [[ "$fq_sym" == *'HTTP_PROXY: ""'* ]] || { echo "file_queue project: expected an empty HTTP_PROXY in the symphony service" >&2; false; }
  [[ "$gl_sym" == *'HTTP_PROXY: http://squid:3128'* ]] || { echo "gitlab project: expected HTTP_PROXY: http://squid:3128 in the symphony service" >&2; false; }
}
