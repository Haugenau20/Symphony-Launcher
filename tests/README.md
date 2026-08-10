# Tests

Automated tests for `./symphony`, written with [bats](https://bats-core.readthedocs.io)
(Bash Automated Testing System). No Docker daemon and no registry access are
required — a fake `docker` stands in for the real one, and the one place a
REAL `docker compose` is used (`compose.bats`) only ever *resolves*
configuration; it never boots anything.

## Run

```bash
./tests/run.sh              # whole suite
./tests/run.sh cli.bats     # one file
```

`run.sh` uses a system `bats` if you have one; otherwise it fetches
`bats-core` into `tests/.bats/` (gitignored) on first run. Installing bats
yourself (`brew install bats-core`, `apt install bats`, …) skips the fetch.

## What's covered

| File | Style | Covers |
| --- | --- | --- |
| `unit_helpers.bats` | sources `./symphony`, calls helpers directly | `validate_project_name`, the `project_*_dir`/`project_*_file`/`project_*_container_name` path helpers (incl. the config-dir/symphony.env containment), `symphony_tracker_kind`, `symphony_wf_scalar`, `env_file_get`, the allowlist normalization trio (`symphony_norm_dest`/`symphony_path_of`/`symphony_covered_by`), `symphony_allowlist_agreement`, `symphony_http_proxy`, `symphony_preflight` (missing-WORKFLOW.md case), `viewer_port_for`/`port_pair_free` |
| `cli.bats` | runs a sandboxed copy of `./symphony` as a subprocess | verb dispatch and arg errors, `init` (scaffolding + idempotency), `check` (missing WORKFLOW.md, file_queue pass, gitlab token requirement, token-reuse warning, leaked `SYMPHONY_*` key warning, the allowlist cross-check), `up` (preflight-abort-before-any-docker-call, the exact service list pulled/started, `--publish`), `logs` (not-running vs. tailing), `status` (per-state counts, the missing-queue-dirs regression, the gitlab tracker board), `stop`/`down`, `add` (file_queue queuing, gitlab refusal), `projects` (excludes `_example`), and a static assertion that neither example env file carries a `SYMPHONY_*` key |
| `compose.bats` | resolves the sandboxed stack with the REAL `docker compose config` | the token-isolation invariant (`SYMPHONY_GITLAB_TOKEN` reaches only the symphony service, exactly once), `/workspace` is always a volume never a bind, `/workspaces` binds to the same host path in both opencode and symphony, `/config` is read-only in symphony, port publishing (none by default, exactly two loopback-bound ports with `--publish`), both internal networks are actually `internal: true`, the stack is pull-only with every image resolving off `IMAGE_REGISTRY`, and egress (`HTTP_PROXY` in the symphony service) is genuinely derived from `tracker.kind` |

**`compose.bats` never boots the stack.** The images this launcher pulls live
in a private registry (`IMAGE_REGISTRY` in `.env`), and the `-symphony` image
in particular may not be published at all yet — see
`docker/docker-compose.symphony.yml`'s own header. `docker compose config`
needs no daemon and no registry access; it only resolves the four env layers
and the compose files into the YAML compose would actually act on, which is
the part of this system that's mechanically verifiable without infrastructure.
Actually pulling images and booting the stack is a manual / CI-with-registry
step, out of scope here. `compose.bats` skips cleanly (not a failure) when
`docker compose version` doesn't work in the current environment at all, so
the rest of the suite still runs on a box with no docker on `PATH`.

## How the harness works

- **`fake-bin/docker`** — a stub on `PATH` that records every call's argv to
  `$FAKE_DOCKER_LOG` and returns a controllable exit code
  (`FAKE_DOCKER_COMPOSE_RC`, default 0). Two exceptions: `docker compose
  config` always delegates to the REAL `docker` on the host (so `cli.bats`'s
  `check` cross-check test, and `compose.bats` calling `docker compose
  ... config` directly, both get genuine resolved YAML rather than a stub),
  and `docker ps --format '{{.Names}}'` prints `$FAKE_DOCKER_PS_OUTPUT` (one
  container name per line) rather than being logged-and-stubbed, since
  several verbs branch on its output.
- **`common.bash`** — `make_sandbox` copies `./symphony`, `lib/`, `docker/`,
  `templates/`, `projects/_example/`, `extra-allowlist.d/` and `.env.example`
  into a per-test temp dir so nothing ever touches the real repo, and puts
  `tests/fake-bin` first on `PATH`. `seed_env` pre-creates `$SANDBOX/.env`
  with a non-placeholder `IMAGE_REGISTRY`. `make_project NAME [file_queue|
  gitlab] [project_id]` writes a minimal valid `WORKFLOW.md` plus the project
  directories, deliberately without the queue state directories (several
  tests rely on those not existing yet). `run_launcher` runs the sandboxed
  `./symphony` as a subprocess. `resolve_compose_config`/`resolve_or_fail` run
  the exact same `symphony_derive_settings` every real verb runs, then the
  real `docker compose ... config`, for `compose.bats`. `service_block`,
  `network_block` and `mount_source` pick apart the resulting YAML.
- **source-guard** — `./symphony` runs `main` only when executed directly
  (`[ "${BASH_SOURCE[0]}" = "${0}" ]`), so `unit_helpers.bats` can `source` it
  for free with no side effects.

## Adding a test

- Pure helper? Add to `unit_helpers.bats`: `source "$REPO_ROOT/symphony"` (see
  `setup()`) then call it directly. Stub collaborators by redefining them as
  functions in the test body (see how the `port_pair_free` tests stub
  `port_in_use`).
- End-to-end CLI behaviour? Add to `cli.bats`: `make_sandbox`, `seed_env`,
  `make_project` as needed, then `run_launcher …` and assert on `$status`,
  `$output`, the generated files under `$SANDBOX/projects/<name>/`, or
  `$FAKE_DOCKER_LOG`.
- A question about what the compose files actually resolve to? Add to
  `compose.bats`: `make_project`, `resolve_or_fail NAME [--publish]`, then
  assert against `$COMPOSE_CONFIG_OUT` (real resolved YAML) with
  `service_block`/`network_block`/`mount_source` or a direct `grep`.
