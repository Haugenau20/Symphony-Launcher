#!/usr/bin/env bats
#
# Unit tests for the pure helpers in lib/*.sh. `./symphony` is side-effect-free
# when sourced (main() only runs when the file is executed directly — see its
# source-guard), so these `source` it and call functions directly rather than
# spawning a subprocess per assertion.

setup() {
  load common
  # PROJECTS_DIR is read at source time by lib/project.sh; point it at a
  # per-test scratch path so nothing here ever touches the real repo's
  # projects/. Individual tests may reassign it afterward (it's a plain
  # variable, read live by every project_*_dir helper, not just at source
  # time) when they need a specific value in their assertions.
  export PROJECTS_DIR="$BATS_TEST_TMPDIR/projects"
  source "$REPO_ROOT/symphony"
}

# --- validate_project_name ---------------------------------------------------

@test "validate_project_name: accepts a normal name" {
  run validate_project_name "acme-1.2_3"
  [ "$status" -eq 0 ]
}

@test "validate_project_name: rejects '..'" {
  run validate_project_name ".."
  [ "$status" -eq 1 ]
  [[ "$output" == *"must start with a letter or digit"* ]]
}

@test "validate_project_name: rejects a name containing a slash" {
  run validate_project_name "a/b"
  [ "$status" -eq 1 ]
  [[ "$output" == *"only letters, digits, dot, underscore and dash"* ]]
}

@test "validate_project_name: rejects a leading dot" {
  run validate_project_name ".hidden"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must start with a letter or digit"* ]]
}

@test "validate_project_name: rejects a leading dash" {
  run validate_project_name "-flag-like"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must start with a letter or digit"* ]]
}

@test "validate_project_name: rejects an empty name" {
  run validate_project_name ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"must not be empty"* ]]
}

# --- project path helpers -----------------------------------------------------

@test "project path helpers: derive projects/<name>/{config,queue,workspaces,.env,symphony.env,config/WORKFLOW.md,allowlist.d}" {
  PROJECTS_DIR="projects"
  run project_root_dir myslug
  [ "$output" = "projects/myslug" ]
  run project_config_dir myslug
  [ "$output" = "projects/myslug/config" ]
  run project_queue_dir myslug
  [ "$output" = "projects/myslug/queue" ]
  run project_workspaces_dir myslug
  [ "$output" = "projects/myslug/workspaces" ]
  run project_env_file myslug
  [ "$output" = "projects/myslug/.env" ]
  run project_symphony_env_file myslug
  [ "$output" = "projects/myslug/symphony.env" ]
  run project_workflow_file myslug
  [ "$output" = "projects/myslug/config/WORKFLOW.md" ]
  run project_allowlist_dir myslug
  [ "$output" = "projects/myslug/allowlist.d" ]
}

@test "project path helpers: container names match docker-compose.{yml,symphony.yml,publish.yml}" {
  run project_opencode_container_name myslug
  [ "$output" = "symphony-myslug-opencode" ]
  run project_container_name myslug
  [ "$output" = "symphony-myslug-orchestrator" ]
  run project_publish_container_name myslug
  [ "$output" = "symphony-myslug-publish" ]
}

@test "project path helpers: config_dir is a SUBDIRECTORY of root_dir, and symphony.env sits OUTSIDE config_dir" {
  # Load-bearing: config_dir is what gets bind-mounted read-only into the
  # symphony container (docker/docker-compose.symphony.yml). symphony.env —
  # which can hold SYMPHONY_GITLAB_TOKEN — must sit outside it, or that mount
  # would expose the orchestrator's own credential to itself unnecessarily
  # and, per lib/symphony.sh's preflight, would be a straight-up misconfig if
  # it ever collided with an AGENT-visible file there.
  run project_root_dir x
  local root="$output"
  run project_config_dir x
  local config_dir="$output"
  [[ "$config_dir" == "$root/config" ]]
  run project_symphony_env_file x
  local sym_env="$output"
  [[ "$sym_env" == "$root/symphony.env" ]]
  # config_dir is a subdirectory of root (starts with "$root/"), but
  # symphony.env is NOT inside config_dir.
  [[ "$config_dir" == "$root/"* ]]
  [[ "$sym_env" != "$config_dir"/* ]]
  [[ "$sym_env" != "$config_dir" ]]
}

# --- symphony_tracker_kind: WORKFLOW.md front-matter parsing -----------------

@test "symphony_tracker_kind: reads tracker.kind from the front matter" {
  local wf="$BATS_TEST_TMPDIR/WORKFLOW.md"
  printf -- '---\ntracker:\n  kind: gitlab\n---\nbody\n' > "$wf"
  run symphony_tracker_kind "$wf"
  [ "$output" = "gitlab" ]
}

@test "symphony_tracker_kind: empty for a missing file" {
  run symphony_tracker_kind "$BATS_TEST_TMPDIR/does-not-exist.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "symphony_tracker_kind: a commented-out kind line never matches" {
  local wf="$BATS_TEST_TMPDIR/WORKFLOW.md"
  printf -- '---\ntracker:\n  # kind: gitlab\n  kind: file_queue\n---\nbody\n' > "$wf"
  run symphony_tracker_kind "$wf"
  [ "$output" = "file_queue" ]
}

# --- symphony_wf_scalar -------------------------------------------------------

@test "symphony_wf_scalar: reads a top-level key, strips trailing comments and quotes" {
  local wf="$BATS_TEST_TMPDIR/WORKFLOW.md"
  printf -- '---\ntracker:\n  kind: gitlab\n  project_id: "mygroup/myproject"  # comment\n---\nbody\n' > "$wf"
  run symphony_wf_scalar "$wf" project_id
  [ "$output" = "mygroup/myproject" ]
}

@test "symphony_wf_scalar: empty when the key is absent" {
  local wf="$BATS_TEST_TMPDIR/WORKFLOW.md"
  printf -- '---\ntracker:\n  kind: file_queue\n---\nbody\n' > "$wf"
  run symphony_wf_scalar "$wf" project_id
  [ -z "$output" ]
}

# --- env_file_get: generic file-scoped env reader ----------------------------

@test "env_file_get: reads a KEY=VALUE line from an arbitrary file" {
  local f="$BATS_TEST_TMPDIR/some.env"
  printf 'FOO=bar\nSYMPHONY_GITLAB_TOKEN=secret123\n' > "$f"
  run env_file_get "$f" SYMPHONY_GITLAB_TOKEN
  [ "$output" = "secret123" ]
}

@test "env_file_get: empty for a missing key or a missing file" {
  local f="$BATS_TEST_TMPDIR/some.env"
  printf 'FOO=bar\n' > "$f"
  run env_file_get "$f" NOPE
  [ -z "$output" ]
  run env_file_get "$BATS_TEST_TMPDIR/no-such-file.env" FOO
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- allowlist normalization/covering (ported from upstream OpenCode-Setup's
# ./scripts/symphony — same three helpers, same test intent) ----------------

@test "symphony_norm_dest: strips scheme/userinfo/port/.git and lowercases" {
  run symphony_norm_dest "https://user@GitLab.Example.com:8443/MyGroup/MyProject.git"
  [ "$output" = "gitlab.example.com/mygroup/myproject" ]
}

@test "symphony_norm_dest: normalizes an scp-style git@host:path remote" {
  run symphony_norm_dest "git@gitlab.example.com:mygroup/myproject.git"
  [ "$output" = "gitlab.example.com/mygroup/myproject" ]
}

@test "symphony_norm_dest: a bare host/path (no scheme) passes through, slashes trimmed" {
  run symphony_norm_dest "/gitlab.example.com/mygroup/myproject/"
  [ "$output" = "gitlab.example.com/mygroup/myproject" ]
}

@test "symphony_path_of: the path part after the first slash, empty for a host-only entry" {
  run symphony_path_of "gitlab.example.com/mygroup/myproject"
  [ "$output" = "mygroup/myproject" ]
  run symphony_path_of "gitlab.example.com"
  [ -z "$output" ]
}

@test "symphony_covered_by: exact match and a deeper path both covered" {
  symphony_covered_by "mygroup/myproject" "mygroup/myproject"
  symphony_covered_by "mygroup/myproject/sub" "mygroup/myproject"
}

@test "symphony_covered_by: a path-segment boundary — 'a/b-evil' is NOT covered by 'a/b'" {
  ! symphony_covered_by "a/b-evil" "a/b"
}

@test "symphony_covered_by: a host-only (empty) entry covers everything" {
  symphony_covered_by "anything/at/all" ""
}

@test "symphony_covered_by: false when nothing matches" {
  ! symphony_covered_by "othergroup/otherproject" "mygroup/myproject"
}

# --- symphony_allowlist_agreement --------------------------------------------

@test "symphony_allowlist_agreement: warns BOTH directions on a mismatch" {
  local wf="$BATS_TEST_TMPDIR/WORKFLOW.md"
  printf -- '---\ntracker:\n  kind: file_queue\n---\nbody\n' > "$wf"
  run symphony_allowlist_agreement "$wf" 1 "gitlab.example.com/othergroup/otherproject" 1 "mygroup/myproject"
  [[ "$output" == *"mygroup/myproject is in GITLAB_WRITE_PROJECTS but no GIT_REMOTE_ALLOWLIST entry covers it"* ]]
  [[ "$output" == *"othergroup/otherproject is pushable per GIT_REMOTE_ALLOWLIST but not in GITLAB_WRITE_PROJECTS"* ]]
}

@test "symphony_allowlist_agreement: silent when both allowlists already agree" {
  local wf="$BATS_TEST_TMPDIR/WORKFLOW.md"
  printf -- '---\ntracker:\n  kind: file_queue\n---\nbody\n' > "$wf"
  # GIT_REMOTE_ALLOWLIST entries are full host/path remotes; GITLAB_WRITE_PROJECTS
  # entries are bare group/project paths — norm_dest+path_of is what makes
  # "gitlab.example.com/mygroup/myproject" and "mygroup/myproject" comparable.
  run symphony_allowlist_agreement "$wf" 1 "gitlab.example.com/mygroup/myproject" 1 "mygroup/myproject"
  [ -z "$output" ]
}

@test "symphony_allowlist_agreement: silent when either gate is off" {
  local wf="$BATS_TEST_TMPDIR/WORKFLOW.md"
  printf -- '---\ntracker:\n  kind: file_queue\n---\nbody\n' > "$wf"
  run symphony_allowlist_agreement "$wf" 0 "" 1 "mygroup/myproject"
  [ -z "$output" ]
}

@test "symphony_allowlist_agreement: cross-checks the gitlab tracker's own project against both allowlists" {
  local wf="$BATS_TEST_TMPDIR/WORKFLOW.md"
  printf -- '---\ntracker:\n  kind: gitlab\n  base_url: https://gitlab.example.com\n  project_id: mygroup/myproject\n---\nbody\n' > "$wf"
  run symphony_allowlist_agreement "$wf" 1 "gitlab.example.com/mygroup/myproject" 1 "mygroup/myproject"
  [[ "$output" == *"tracker project gitlab.example.com/mygroup/myproject is git-reachable and API-writable"* ]]
}

@test "symphony_allowlist_agreement: warns when the tracker project itself is not covered" {
  local wf="$BATS_TEST_TMPDIR/WORKFLOW.md"
  printf -- '---\ntracker:\n  kind: gitlab\n  base_url: https://gitlab.example.com\n  project_id: mygroup/myproject\n---\nbody\n' > "$wf"
  run symphony_allowlist_agreement "$wf" 1 "gitlab.example.com/othergroup/otherproject" 0 ""
  [[ "$output" == *"tracker project gitlab.example.com/mygroup/myproject is not covered by GIT_REMOTE_ALLOWLIST"* ]]
}

@test "symphony_allowlist_agreement: a numeric project_id has no path to compare, so no tracker cross-check fires" {
  local wf="$BATS_TEST_TMPDIR/WORKFLOW.md"
  printf -- '---\ntracker:\n  kind: gitlab\n  base_url: https://gitlab.example.com\n  project_id: "12345"\n---\nbody\n' > "$wf"
  run symphony_allowlist_agreement "$wf" 1 "gitlab.example.com/mygroup/myproject" 0 ""
  [[ "$output" != *"tracker project"* ]]
}

# --- symphony_http_proxy: egress derivation from tracker.kind ----------------

@test "symphony_http_proxy: empty for the file queue (no egress at all)" {
  local wf="$BATS_TEST_TMPDIR/WORKFLOW.md"
  printf -- '---\ntracker:\n  kind: file_queue\n---\nbody\n' > "$wf"
  ( unset SYMPHONY_HTTP_PROXY; run symphony_http_proxy "$wf"; [ -z "$output" ] )
}

@test "symphony_http_proxy: defaults to http://squid:3128 for the gitlab tracker" {
  local wf="$BATS_TEST_TMPDIR/WORKFLOW.md"
  printf -- '---\ntracker:\n  kind: gitlab\n---\nbody\n' > "$wf"
  ( unset SYMPHONY_HTTP_PROXY; run symphony_http_proxy "$wf"; [ "$output" = "http://squid:3128" ] )
}

@test "symphony_http_proxy: an explicit SYMPHONY_HTTP_PROXY always wins" {
  local wf="$BATS_TEST_TMPDIR/WORKFLOW.md"
  printf -- '---\ntracker:\n  kind: file_queue\n---\nbody\n' > "$wf"
  SYMPHONY_HTTP_PROXY="http://custom:8080" run symphony_http_proxy "$wf"
  [ "$output" = "http://custom:8080" ]
}

# --- symphony_preflight -------------------------------------------------------

@test "symphony_preflight: fatal on a missing WORKFLOW.md" {
  PROJECTS_DIR="$BATS_TEST_TMPDIR/projects"
  run symphony_preflight myslug
  [ "$status" -eq 1 ]
  [[ "$output" == *"no ${PROJECTS_DIR}/myslug/config/WORKFLOW.md"* ]]
}

# --- viewer_port_for / port_pair_free (opencode-pty viewer-port coupling) ---
# Fresh port assignment must never hand out a base port whose derived
# opencode-pty viewer port (1<base>) is already taken by something else —
# the publish overlay's second socat leg would then fail to bind, breaking
# `docker compose up`. See lib/project.sh.

@test "viewer_port_for: prepends a literal '1' to the base port" {
  run viewer_port_for 4096
  [ "$output" = "14096" ]
}

@test "port_pair_free: true when neither the base nor its viewer port is busy" {
  port_in_use() { return 1; }   # nothing busy
  run port_pair_free 4096
  [ "$status" -eq 0 ]
}

@test "port_pair_free: false when only the base port is busy" {
  port_in_use() { [ "$1" = 4096 ] && return 0 || return 1; }
  run port_pair_free 4096
  [ "$status" -ne 0 ]
}

@test "port_pair_free: false when only the viewer port is busy" {
  port_in_use() { [ "$1" = 14096 ] && return 0 || return 1; }
  run port_pair_free 4096
  [ "$status" -ne 0 ]
}
