#!/usr/bin/env bats
#
# Black-box tests: run a sandboxed copy of ./symphony as a subprocess with a
# fake `docker` on PATH, and assert on its exit status, messages and side
# effects (generated files under projects/<name>/, and the recorded docker
# calls in $FAKE_DOCKER_LOG).

setup() {
  load common
  make_sandbox
}

# --- argument parsing / dispatch ---------------------------------------------

@test "no verb prints usage and exits 1" {
  run_launcher
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown verb is rejected" {
  run_launcher bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown verb 'bogus'"* ]]
}

# --- check --------------------------------------------------------------------

@test "check: requires a project name" {
  seed_env
  run_launcher check
  [ "$status" -eq 1 ]
  [[ "$output" == *"check requires a project name"* ]]
}

@test "check: rejects an invalid project name" {
  seed_env
  run_launcher check "../evil"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid project name"* ]]
}

@test "check: fatal on a missing WORKFLOW.md, suggesting BOTH templates" {
  seed_env
  mkdir -p "$SANDBOX/projects/my-svc"
  run_launcher check my-svc
  [ "$status" -eq 1 ]
  [[ "$output" == *"no projects/my-svc/config/WORKFLOW.md"* ]]
  [[ "$output" == *"WORKFLOW.md.example"* ]]
  [[ "$output" == *"WORKFLOW.gitlab.md.example"* ]]
  [[ "$output" == *"preflight failed"* ]]
}

@test "check: passes on a correctly configured file_queue project" {
  seed_env
  make_project my-svc file_queue
  run_launcher check my-svc
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracker: file_queue"* ]]
  [[ "$output" == *"file queue: symphony holds no credentials"* ]]
  [[ "$output" == *"check passed."* ]]
}

@test "check: refuses a gitlab tracker with no SYMPHONY_GITLAB_TOKEN" {
  seed_env
  make_project my-svc gitlab
  run_launcher check my-svc
  [ "$status" -eq 1 ]
  [[ "$output" == *"tracker is gitlab but SYMPHONY_GITLAB_TOKEN is empty"* ]]
  [[ "$output" == *"projects/my-svc/symphony.env"* ]]
  [[ "$output" == *"preflight failed"* ]]
}

@test "check: passes on a gitlab tracker once SYMPHONY_GITLAB_TOKEN is set" {
  seed_env
  make_project my-svc gitlab
  printf 'SYMPHONY_GITLAB_TOKEN=reporter-token-abc\n' > "$SANDBOX/projects/my-svc/symphony.env"
  run_launcher check my-svc
  [ "$status" -eq 0 ]
  [[ "$output" == *"SYMPHONY_GITLAB_TOKEN set"* ]]
  [[ "$output" == *"check passed."* ]]
}

@test "check: REFUSES when SYMPHONY_GITLAB_TOKEN and GITLAB_PAT are the same token" {
  seed_env
  make_project my-svc gitlab
  printf 'GITLAB_PAT=shared-token-123\n' > "$SANDBOX/projects/my-svc/.env"
  printf 'SYMPHONY_GITLAB_TOKEN=shared-token-123\n' > "$SANDBOX/projects/my-svc/symphony.env"
  run_launcher check my-svc
  # Fatal, not a warning, and fatal WITHOUT depending on docker being present:
  # one token doing both jobs leaves no containment to warn about. See the
  # comment on this check in lib/symphony.sh.
  [ "$status" -eq 1 ]
  [[ "$output" == *"SYMPHONY_GITLAB_TOKEN and GITLAB_PAT are the same token"* ]]
  [[ "$output" == *"the two-token split IS the containment"* ]]
  # The resolved-config cross-check must NOT be what produced this: it reports
  # a leak through the env layering, which is a different fault with a
  # different fix, and there is no leak here.
  [[ "$output" != *"appears in the resolved opencode service config"* ]]
}

@test "check: warns when a SYMPHONY_* key leaks into the agent-visible .env" {
  seed_env
  make_project my-svc file_queue
  printf 'SYMPHONY_LEAKED_KEY=oops\n' >> "$SANDBOX/.env"
  run_launcher check my-svc
  [ "$status" -eq 0 ]
  [[ "$output" == *"SYMPHONY_* key(s) in"* ]]
  [[ "$output" == *"SYMPHONY_LEAKED_KEY"* ]]
}

@test "check: allowlist cross-check warns when GITLAB_WRITE_PROJECTS is not covered by GIT_REMOTE_ALLOWLIST" {
  seed_env
  make_project my-svc gitlab mygroup/myproject
  printf 'SYMPHONY_GITLAB_TOKEN=reporter-token\n' > "$SANDBOX/projects/my-svc/symphony.env"
  sed -i 's|^ALLOW_REMOTE_GIT=.*|ALLOW_REMOTE_GIT=1|' "$SANDBOX/.env"
  sed -i 's|^GIT_REMOTE_ALLOWLIST=.*|GIT_REMOTE_ALLOWLIST=gitlab.example.com/othergroup/otherproject|' "$SANDBOX/.env"
  sed -i 's|^ALLOW_GITLAB_WRITE=.*|ALLOW_GITLAB_WRITE=1|' "$SANDBOX/.env"
  sed -i 's|^GITLAB_WRITE_PROJECTS=.*|GITLAB_WRITE_PROJECTS=mygroup/myproject|' "$SANDBOX/.env"
  run_launcher check my-svc
  [ "$status" -eq 0 ]
  [[ "$output" == *"mygroup/myproject is in GITLAB_WRITE_PROJECTS but no GIT_REMOTE_ALLOWLIST entry covers it"* ]]
  [[ "$output" == *"tracker project gitlab.example.com/mygroup/myproject is not covered by GIT_REMOTE_ALLOWLIST"* ]]
}

@test "check: allowlist cross-check stays silent when both allowlists agree with the tracker project" {
  seed_env
  make_project my-svc gitlab mygroup/myproject
  printf 'SYMPHONY_GITLAB_TOKEN=reporter-token\n' > "$SANDBOX/projects/my-svc/symphony.env"
  sed -i 's|^ALLOW_REMOTE_GIT=.*|ALLOW_REMOTE_GIT=1|' "$SANDBOX/.env"
  sed -i 's|^GIT_REMOTE_ALLOWLIST=.*|GIT_REMOTE_ALLOWLIST=gitlab.example.com/mygroup/myproject|' "$SANDBOX/.env"
  sed -i 's|^ALLOW_GITLAB_WRITE=.*|ALLOW_GITLAB_WRITE=1|' "$SANDBOX/.env"
  sed -i 's|^GITLAB_WRITE_PROJECTS=.*|GITLAB_WRITE_PROJECTS=mygroup/myproject|' "$SANDBOX/.env"
  run_launcher check my-svc
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracker project gitlab.example.com/mygroup/myproject is git-reachable and API-writable"* ]]
  [[ "$output" != *"is not covered by"* ]]
  [[ "$output" != *"is not in GITLAB_WRITE_PROJECTS"* ]]
}

# --- init -----------------------------------------------------------------

@test "init: scaffolds projects/<name>/{config,queue/*,workspaces} and both env files, and is idempotent" {
  seed_env
  run_launcher init my-svc
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/projects/my-svc/config" ]
  [ -d "$SANDBOX/projects/my-svc/workspaces" ]
  for d in todo in-progress review done failed cancelled; do
    [ -d "$SANDBOX/projects/my-svc/queue/$d" ]
  done
  [ -f "$SANDBOX/projects/my-svc/.env" ]
  [ -f "$SANDBOX/projects/my-svc/symphony.env" ]
  [[ "$output" == *"scaffolded projects/my-svc"* ]]

  # Idempotent: a second run must never overwrite either env file.
  printf '\nMARKER=yes\n' >> "$SANDBOX/projects/my-svc/.env"
  run_launcher init my-svc
  [ "$status" -eq 0 ]
  [[ "$output" == *"already present"* ]]
  grep -q "MARKER=yes" "$SANDBOX/projects/my-svc/.env"
}

# --- up -------------------------------------------------------------------

@test "up: a failed preflight aborts before ANY docker call" {
  seed_env
  # No WORKFLOW.md at all -> preflight fails.
  run_launcher up my-svc
  [ "$status" -eq 1 ]
  [[ "$output" == *"preflight failed"* ]]
  [ ! -s "$FAKE_DOCKER_LOG" ]
}

@test "up: pulls and starts exactly opencode+squid+symphony under -p symphony-<name>, never a publisher" {
  seed_env
  make_project my-svc file_queue
  run_launcher up my-svc
  [ "$status" -eq 0 ]
  grep -q 'compose .*-p symphony-my-svc .*pull opencode squid symphony$' "$FAKE_DOCKER_LOG"
  grep -q 'compose .*-p symphony-my-svc .*up -d opencode squid symphony$' "$FAKE_DOCKER_LOG"
  ! grep -q 'publish' "$FAKE_DOCKER_LOG"
}

@test "up --publish: adds docker-compose.publish.yml and starts the publish service" {
  seed_env
  make_project my-svc file_queue
  run_launcher up my-svc --publish
  [ "$status" -eq 0 ]
  grep -q 'docker-compose.publish.yml' "$FAKE_DOCKER_LOG"
  grep -q 'compose .*up -d opencode squid symphony publish$' "$FAKE_DOCKER_LOG"
}

# --- logs -------------------------------------------------------------------

@test "logs: reports 'not running' (no compose call) when the container is down" {
  seed_env
  make_project my-svc file_queue
  run_launcher logs my-svc
  [ "$status" -eq 0 ]
  [[ "$output" == *"symphony-my-svc-orchestrator is not running"* ]]
  ! grep -q 'compose .*logs' "$FAKE_DOCKER_LOG"
}

@test "logs: tails the symphony service when its container IS running" {
  seed_env
  make_project my-svc file_queue
  FAKE_DOCKER_PS_OUTPUT="symphony-my-svc-orchestrator" run_launcher logs my-svc
  [ "$status" -eq 0 ]
  grep -q 'compose .*logs -f --tail=100 symphony' "$FAKE_DOCKER_LOG"
}

# --- status -------------------------------------------------------------------

@test "status: reports per-state queue counts (not the tracker board) for a file_queue project" {
  seed_env
  make_project my-svc file_queue
  mkdir -p "$SANDBOX/projects/my-svc/queue/todo"
  : > "$SANDBOX/projects/my-svc/queue/todo/SYM-1-do-a-thing.md"
  run_launcher status my-svc
  [ "$status" -eq 0 ]
  [[ "$output" == *"queue:"* ]]
  [[ "$output" == *"todo"* ]]
  [[ "$output" == *"symphony: NOT running"* ]]
}

@test "status: works with no queue dirs on disk at all (find-on-missing-dir regression, pipefail must not abort)" {
  seed_env
  make_project my-svc file_queue
  # No queue/ dirs on disk at all yet (init/up never ran).
  run_launcher status my-svc
  [ "$status" -eq 0 ]
  [[ "$output" == *"queue is empty"* ]]
}

@test "status: reports the tracker's project for a gitlab project, NOT file counts" {
  seed_env
  make_project my-svc gitlab mygroup/myproject
  run_launcher status my-svc
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracker: gitlab — mygroup/myproject"* ]]
}

# --- stop / down --------------------------------------------------------------

@test "stop: stops only the symphony service" {
  seed_env
  make_project my-svc file_queue
  run_launcher stop my-svc
  [ "$status" -eq 0 ]
  grep -q 'compose .*stop symphony' "$FAKE_DOCKER_LOG"
}

@test "down: tears down the whole stack" {
  seed_env
  make_project my-svc file_queue
  run_launcher down my-svc
  [ "$status" -eq 0 ]
  grep -q 'compose .*down' "$FAKE_DOCKER_LOG"
  [[ "$output" == *"is down."* ]]
}

# --- add ------------------------------------------------------------------

@test "add: queues an item under todo/ for a file_queue project" {
  seed_env
  make_project my-svc file_queue
  run_launcher add my-svc "fix the token refresh race" --id SYM-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"queued"* ]]
  local f="$SANDBOX/projects/my-svc/queue/todo/SYM-1-fix-the-token-refresh-race.md"
  [ -f "$f" ]
  grep -q '^id: SYM-1$' "$f"
  grep -q 'fix the token refresh race' "$f"
}

@test "add: refuses under tracker: gitlab (work items are issues, not files)" {
  seed_env
  make_project my-svc gitlab
  run_launcher add my-svc "do something"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the tracker is gitlab"* ]]
  [[ "$output" == *"symphony::todo"* ]]
}

# --- projects -------------------------------------------------------------

@test "projects: excludes the _example template" {
  seed_env
  make_project my-svc file_queue
  run_launcher projects
  [ "$status" -eq 0 ]
  [[ "$output" == *"my-svc"* ]]
  [[ "$output" != *"_example"* ]]
}

@test "projects: on a fresh checkout with only _example present, reports 'no projects yet' rather than listing the template" {
  seed_env
  run_launcher projects
  [ "$status" -eq 0 ]
  [[ "$output" == *"no projects yet"* ]]
  [[ "$output" != *"_example"* ]]
}

# --- static credential-hygiene assertions ------------------------------------

@test ".env.example and projects/_example/.env.example never carry a SYMPHONY_* key" {
  # Anchored to an actual KEY=... assignment, not a substring match — both
  # files legitimately mention "SYMPHONY_*" in prose explaining why it must
  # stay out.
  run grep -E '^SYMPHONY_[A-Z_]*=' "$REPO_ROOT/.env.example"
  [ "$status" -eq 1 ]
  run grep -E '^SYMPHONY_[A-Z_]*=' "$REPO_ROOT/projects/_example/.env.example"
  [ "$status" -eq 1 ]
}
