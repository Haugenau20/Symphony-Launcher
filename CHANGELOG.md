# Changelog

Changelog for **Symphony-Launcher**. Format loosely based on
[Keep a Changelog](https://keepachangelog.com/).

This launcher and the images it pulls (`opencode`, `-squid`, `-symphony`)
are versioned and released independently — a launcher release does not
imply a new image, and vice versa. `IMAGE_TAG=latest` (the default in
`.env.example`) always pulls the newest upload; pin an explicit tag in
`.env` for a reproducible unattended run.

## [Unreleased]

### Fewer docker networks per stack

Collapsed each project's docker networks from three or four down to two:
`oc_internal` is gone (its membership was always a strict subset of
`oc_proxy`'s, so it enforced nothing `oc_proxy` did not already enforce),
and `oc_egress`/`oc_publish` are now one network, `oc_external`. Every
bridge network draws a subnet from dockerd's address-pool budget
(`172.16.0.0/12` and `192.168.0.0/16` carved into predefined pools by
default, with no `default-address-pools` override), and a host running
several of these stacks alongside other docker tooling can exhaust that
budget, failing a stack boot with "all predefined address pools have been
fully subnetted." Halving the per-stack draw is the point. The invariant
that made this safe to do — no agent container (`opencode`,
`opencode-review`, `symphony`, `symphony-review`) may ever sit on a
non-internal network, so `squid` stays the only route off-host — is now
also an explicit `compose.bats` test, not just a comment.

### Review: inline comments

`review.inline_comments` (shipped default: `true`). A finding that can be
tied to a specific line is now posted as a comment on that line in the
merge request's Changes view, instead of only appearing in the summary
comment. A finding whose line cannot be confirmed against the diff still
falls back to the summary comment rather than being guessed at, and the
summary comment is still posted on every review — with or without inline
findings, and even with none at all. Re-reviewing a new commit replies to
the previous revision's inline threads and attempts to resolve them; a
Reporter-role token may not be permitted to resolve one, in which case the
reply stands on its own and the thread stays open.

## [0.1.0] — 2026-08-10

Initial release. A launcher for **Symphony**: an unattended orchestrator
that runs an OpenCode agent, headless, against a queue of work items —
either markdown files in a directory tree (`tracker.kind: file_queue`) or
GitLab issues carrying a `symphony::` label (`tracker.kind: gitlab`) — until
each item is ready for a human. Pull-only: three images
(`opencode`, `-squid`, `-symphony`) from a container registry you configure,
wired together with `docker compose`, no build step.

### Design

The orchestration shape is four environment layers (shared vs. per-project,
crossed with agent-visible vs. launcher-only), a per-project
`projects/<name>/{.,symphony}.env` pair, a trusted, read-only
`config/WORKFLOW.md` mount, a six-directory file queue, and a two-token
GitLab split where the orchestrator's Reporter token and the agent's
Developer token can never do each other's job. See the README's
"Configuration: four layers" and "The security model" for the full
rationale.

Every verb takes a **project name**, never a host-repo path —
`validate_project_name` is the entire identity surface, and one checkout
runs any number of independent projects under `projects/<name>/`. There is
no bind mount of a host repository anywhere in this stack: `/workspace` is
always an empty named volume, and the agent clones each item fresh into
`/workspaces/<item>` and never reads `/workspace` at all — an unattended
agent operating on a real checkout is not a risk worth carrying for a
convenience nobody is present to use.

No web UI is exposed by default. `docker-compose.publish.yml` is a third,
opt-in file added only by `up --publish`, binding loopback-only debug
ports — an unattended stack has no web UI worth exposing otherwise.

### Verification status

Honest, not reassuring:

- **This stack has never been booted.** Every check so far is at
  `docker compose config` level — resolved environment, resolved volumes,
  resolved credential placement (the Reporter token appears exactly once in
  the whole stack, under the `symphony` service, never under `opencode`).
  Real checks, but none of them is a boot. The `-symphony` image may not
  even be published in your registry yet — a pull failure on it is an
  **expected state**, not a bug here.
- **The GitLab integration has never touched a live API.** The tracker and
  the API write tools live inside the images this launcher runs, not in this
  repository, and this test suite does not exercise them — it verifies
  configuration resolution. They have been tested only against mocks.
  Assume the first real run against a real GitLab project finds bugs; see
  [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md), which is written
  with that assumption built in.
