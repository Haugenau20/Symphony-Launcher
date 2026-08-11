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

# --- 1b. THE review token-isolation invariant (the THIRD credential) --------
# Same guarantee, extended to SYMPHONY_REVIEW_GITLAB_TOKEN: it must reach
# compose ONLY via --env-file and land in a container ONLY through the
# symphony-review service's own `environment:` block — and, unlike the
# orchestrator's token, it must never appear in EITHER agent service
# (opencode or opencode-review). A whole-config grep would not catch a leak
# into the wrong service — see service_block, which isolates the exact block
# the same way cmd_check's own awk does.

@test "THE REVIEW TOKEN-ISOLATION INVARIANT: SYMPHONY_REVIEW_GITLAB_TOKEN appears exactly once, only inside symphony-review, never inside opencode or opencode-review" {
  make_project my-svc gitlab
  printf 'SYMPHONY_GITLAB_TOKEN=REPORTER-TOKEN-DISTINCT-VALUE-99999\n' > "$SANDBOX/projects/my-svc/symphony.env"
  printf 'GITLAB_PAT=AGENT-PAT-DISTINCT-VALUE-77777\n' > "$SANDBOX/projects/my-svc/.env"
  cat > "$SANDBOX/projects/my-svc/config/REVIEW.md" <<'EOF'
---
review:
  base_url: https://gitlab.example.com
---
body
EOF
  printf 'SYMPHONY_REVIEW_GITLAB_TOKEN=REVIEW-TOKEN-DISTINCT-VALUE-55555\n' > "$SANDBOX/projects/my-svc/review.env"

  resolve_or_fail my-svc
  local out="$COMPOSE_CONFIG_OUT"

  local count
  count="$(grep -c "REVIEW-TOKEN-DISTINCT-VALUE-55555" "$out")"
  if [ "$count" -ne 1 ]; then
    echo "INVARIANT BROKEN: SYMPHONY_REVIEW_GITLAB_TOKEN's value appears $count time(s) in the resolved stack (want exactly 1)." >&2
    echo "It must reach compose ONLY via --env-file and land in a container ONLY through symphony-review's own" >&2
    echo "environment: block — see lib/symphony.sh's header and docker/docker-compose.review.yml." >&2
    false
  fi

  local rev_block opencode_block opencode_review_block
  rev_block="$(service_block "$out" symphony-review)"
  opencode_block="$(service_block "$out" opencode)"
  opencode_review_block="$(service_block "$out" opencode-review)"

  if [[ "$rev_block" != *"REVIEW-TOKEN-DISTINCT-VALUE-55555"* ]]; then
    echo "INVARIANT BROKEN: the review token's one occurrence is NOT inside the symphony-review service block." >&2
    false
  fi
  if [[ "$opencode_block" == *"REVIEW-TOKEN-DISTINCT-VALUE-55555"* ]]; then
    echo "INVARIANT BROKEN: SYMPHONY_REVIEW_GITLAB_TOKEN leaked into the opencode service's resolved config." >&2
    false
  fi
  if [[ "$opencode_review_block" == *"REVIEW-TOKEN-DISTINCT-VALUE-55555"* ]]; then
    echo "INVARIANT BROKEN: SYMPHONY_REVIEW_GITLAB_TOKEN leaked into the opencode-review service's resolved config —" >&2
    echo "the reviewing agent must never hold the credential that trusted code uses to publish its own findings." >&2
    false
  fi
}

@test "THE REVIEWER-CANNOT-PUSH INVARIANT: GITLAB_PAT never appears in the opencode-review service's resolved config" {
  make_project my-svc gitlab
  printf 'SYMPHONY_GITLAB_TOKEN=REPORTER-TOKEN-DISTINCT-VALUE-99999\n' > "$SANDBOX/projects/my-svc/symphony.env"
  printf 'GITLAB_PAT=AGENT-PAT-DISTINCT-VALUE-77777\n' > "$SANDBOX/projects/my-svc/.env"
  cat > "$SANDBOX/projects/my-svc/config/REVIEW.md" <<'EOF'
---
review:
  base_url: https://gitlab.example.com
---
body
EOF
  printf 'SYMPHONY_REVIEW_GITLAB_TOKEN=REVIEW-TOKEN-DISTINCT-VALUE-55555\n' > "$SANDBOX/projects/my-svc/review.env"

  resolve_or_fail my-svc
  local out="$COMPOSE_CONFIG_OUT"

  local opencode_block opencode_review_block
  opencode_block="$(service_block "$out" opencode)"
  opencode_review_block="$(service_block "$out" opencode-review)"

  if [[ "$opencode_review_block" == *"AGENT-PAT-DISTINCT-VALUE-77777"* ]]; then
    echo "INVARIANT BROKEN: GITLAB_PAT leaked into opencode-review's resolved config — this is the check that is" >&2
    echo "supposed to make 'the reviewer cannot push' mechanical rather than instructional." >&2
    false
  fi
  # Sanity: GITLAB_PAT still legitimately reaches opencode, unaffected by
  # review being enabled alongside it — the implementation agent keeps its
  # own credential exactly as before.
  [[ "$opencode_block" == *"AGENT-PAT-DISTINCT-VALUE-77777"* ]]
}

# --- 1c. GITLAB_PAT absent from opencode-review even with NO GITLAB_PAT at all
# in the review-only shape (no WORKFLOW.md, no .env credential at all) —
# guards against the check vacuously passing only because nothing was ever
# configured to leak.

@test "opencode-review's env_file layer is the shared .env ALONE — projects/<name>/.env never reaches it" {
  mkdir -p "$SANDBOX/projects/rev-only/config" "$SANDBOX/projects/rev-only/workspaces"
  printf 'GITLAB_PAT=SHOULD-NEVER-LEAK-INTO-REVIEW-99999\n' > "$SANDBOX/projects/rev-only/.env"
  cat > "$SANDBOX/projects/rev-only/config/REVIEW.md" <<'EOF'
---
review:
  base_url: https://gitlab.example.com
---
body
EOF
  printf 'SYMPHONY_REVIEW_GITLAB_TOKEN=REVIEW-TOKEN-DISTINCT-VALUE-2\n' > "$SANDBOX/projects/rev-only/review.env"

  resolve_or_fail rev-only
  local opencode_review_block
  opencode_review_block="$(service_block "$COMPOSE_CONFIG_OUT" opencode-review)"
  [[ "$opencode_review_block" != *"SHOULD-NEVER-LEAK-INTO-REVIEW-99999"* ]]
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

@test "review egress is granted in symphony-review even with NO tracker configured at all (review-only, no WORKFLOW.md)" {
  # A review-only deployment (the primary one — see templates/REVIEW.md.example)
  # may configure no implementation tracker whatsoever. SYMPHONY_REVIEW_GITLAB_TOKEN
  # alone must be enough to grant squid — the reviewer's whole job is talking
  # to GitLab, independent of tracker.kind.
  mkdir -p "$SANDBOX/projects/rev-only/config" "$SANDBOX/projects/rev-only/workspaces"
  cat > "$SANDBOX/projects/rev-only/config/REVIEW.md" <<'EOF'
---
review:
  base_url: https://gitlab.example.com
---
body
EOF
  printf 'SYMPHONY_REVIEW_GITLAB_TOKEN=REVIEW-TOKEN-DISTINCT-VALUE-3\n' > "$SANDBOX/projects/rev-only/review.env"

  resolve_or_fail rev-only
  local rev_block; rev_block="$(service_block "$COMPOSE_CONFIG_OUT" symphony-review)"
  [[ "$rev_block" == *'HTTP_PROXY: http://squid:3128'* ]] \
    || { echo "review-only project: expected HTTP_PROXY: http://squid:3128 in the symphony-review service" >&2; false; }
}

@test "review egress is granted on top of a file_queue tracker too, and SYMPHONY_HTTP_PROXY is the ONE shared derivation both services read" {
  # symphony_http_proxy (lib/symphony.sh) computes ONE value, SYMPHONY_HTTP_PROXY,
  # that BOTH docker-compose.symphony.yml's symphony service and
  # docker-compose.review.yml's symphony-review service reference — "if
  # review is enabled, return the proxy regardless" therefore widens the
  # file_queue project's egress for BOTH, not just for symphony-review. This
  # is intentional, not a leak: the orchestrator still holds no GitLab
  # credential of its own on file_queue (SYMPHONY_GITLAB_TOKEN stays empty —
  # see the token-isolation invariant), and squid's own allowlist is what
  # actually gates reachable hosts either way.
  make_project fq-plus-review file_queue
  cat > "$SANDBOX/projects/fq-plus-review/config/REVIEW.md" <<'EOF'
---
review:
  base_url: https://gitlab.example.com
---
body
EOF
  printf 'SYMPHONY_REVIEW_GITLAB_TOKEN=REVIEW-TOKEN-DISTINCT-VALUE-4\n' > "$SANDBOX/projects/fq-plus-review/review.env"

  resolve_or_fail fq-plus-review
  local out="$COMPOSE_CONFIG_OUT"
  local sym_block rev_block
  sym_block="$(service_block "$out" symphony)"
  rev_block="$(service_block "$out" symphony-review)"

  [[ "$sym_block" == *'HTTP_PROXY: http://squid:3128'* ]]
  [[ "$rev_block" == *'HTTP_PROXY: http://squid:3128'* ]]
}

# --- 9. the review overlay is additive and opt-in ----------------------------

@test "an ordinary implementation-only project's resolved config has NO opencode-review or symphony-review service at all" {
  make_project my-svc file_queue
  resolve_or_fail my-svc
  local out="$COMPOSE_CONFIG_OUT"
  ! grep -qE '^  opencode-review:' "$out"
  ! grep -qE '^  symphony-review:' "$out"
}

@test "no build: key in docker-compose.review.yml either (pull-only holds for the review overlay too)" {
  run bash -c "grep -nE '^[[:space:]]*build:' '$SANDBOX/docker/docker-compose.review.yml'"
  [ "$status" -eq 1 ]
}

@test "docker-compose.review.yml resolves opencode-review and -symphony images off \${IMAGE_REGISTRY}, same tag as everything else" {
  mkdir -p "$SANDBOX/projects/rev-only/config" "$SANDBOX/projects/rev-only/workspaces"
  cat > "$SANDBOX/projects/rev-only/config/REVIEW.md" <<'EOF'
---
review:
  base_url: https://gitlab.example.com
---
body
EOF
  printf 'SYMPHONY_REVIEW_GITLAB_TOKEN=REVIEW-TOKEN-DISTINCT-VALUE-5\n' > "$SANDBOX/projects/rev-only/review.env"
  resolve_or_fail rev-only
  local out="$COMPOSE_CONFIG_OUT"

  grep -q '^    image: reg\.test\.local/opencode:latest$' "$out"
  grep -q '^    image: reg\.test\.local/opencode-symphony:latest$' "$out"
}
