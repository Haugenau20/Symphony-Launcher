# Changelog

Changelog for **Symphony-Launcher**. Format loosely based on
[Keep a Changelog](https://keepachangelog.com/).

This launcher and the images it pulls (`opencode`, `-squid`, `-symphony`)
are versioned and released independently — a launcher release does not
imply a new image, and vice versa. `IMAGE_TAG=latest` (the default in
`.env.example`) always pulls the newest upload; pin an explicit tag in
`.env` for a reproducible unattended run.

## [0.1.0] — 2026-08-10

Initial release. A launcher for **Symphony**: an unattended orchestrator
that runs an OpenCode agent, headless, against a queue of work items —
either markdown files in a directory tree (`tracker.kind: file_queue`) or
GitLab issues carrying a `symphony::` label (`tracker.kind: gitlab`) — until
each item is ready for a human. Pull-only: three images
(`opencode`, `-squid`, `-symphony`) from a configured Artifactory registry,
wired together with `docker compose`, no build step.

### Where this came from

Symphony was first ported into
[Opencode-Launcher](https://github.com/Haugenau20/Opencode-Launcher)
(commit `3a8fa50`) and then reverted there (`eb36763`) in favor of moving it
to this dedicated repo. The revert's own reasoning is the honest account of
why: Opencode-Launcher is built around one human, one local repo, one
session, torn down on exit — `--continue`, `--persist`, `--exec`, `--shell`,
the TUI attach, the boot-time upgrade gate. Symphony is the opposite of
every part of that: no human, no local repo, runs until stopped. The port
had already accumulated three accommodations pulling in that same
direction, and the required `<host-repo-path>` argument existed only to
derive a project slug and satisfy a mount nothing reads.

That argument turned out to be a real defect rather than an oddity: it fed
the base stack's `${REPO_PATH}:/workspace` bind, giving an **unattended**
agent read-write access to the developer's actual checkout — and
`/workspace`, being OpenCode's project root, sits behind no
`permission.external_directory` gate at all, unlike everything under
`/workspaces`. Fixed in the maintainer repo (OpenCode-Setup's own symphony
overlay now overrides that mount) and structurally impossible here: this
launcher owns its own compose stack and never declares a host-repo bind at
all, anywhere.

### What changed in the port

Ported the shape of the orchestration (four env layers, per-project
`projects/<name>/{.,symphony}.env`, the trusted `config/WORKFLOW.md`
mount, the six-directory file queue, the two-token GitLab split) from the
maintainer repo's `scripts/symphony` and `docs/MULTI_PROJECT.md`, and
changed what the earlier port got wrong or what a dedicated repo makes
possible to do differently:

- **No `<host-repo-path>` argument, anywhere.** Every verb takes a
  **project name**; `validate_project_name` is the entire identity surface.
  This is the actual fix for the defect above, not just a symptom of moving
  repos.
- **No host-repo bind, in either compose file.** `docker-compose.yml` is
  the unattended agent substrate from its first line — `/workspace` is
  always an empty named volume; the agent clones each item fresh into
  `/workspaces/<item>` and never reads `/workspace` at all.
- **No publisher by default.** `docker-compose.publish.yml` is a third,
  opt-in file added only by `up --publish`, binding loopback-only debug
  ports. An unattended stack has no web UI worth exposing otherwise.
- **A project-name CLI throughout**, not a sub-dispatch bolted onto an
  existing one — `init check up logs status stop down add config projects`
  are first-class verbs of `./symphony`, not a `--symphony <verb>` swallowed
  into another script's argv.

### Verification status

Honest, not reassuring:

- **This stack has never been booted.** Every check so far is at
  `docker compose config` level — resolved environment, resolved volumes,
  resolved credential placement (the Reporter token appears exactly once in
  the whole stack, under the `symphony` service, never under `opencode`).
  Real checks, but none of them is a boot. The `-symphony` image may not
  even be published in your registry yet, since the maintainer repo's
  release that publishes it may not have been cut — a pull failure on it is
  an **expected state**, not a bug here.
- **The GitLab integration has never touched a live API.** Per the
  maintainer repo's own documentation, `GitLabTracker` and all six MCP
  write tools (`create_merge_request`, `update_merge_request`,
  `create_mr_note`, `create_issue`, `create_issue_note`,
  `update_issue_note`) are unit-tested against mocks only. Assume the first
  real run against a real GitLab project finds bugs; see
  [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md), which is written
  with that assumption built in.
- **`templates/WORKFLOW{,.gitlab}.md.example`** are verified byte-for-byte
  identical to the maintainer repo's copies as of this release — see
  [`docs/SYNC.md`](docs/SYNC.md) for the verification date and what to
  re-check when either changes.
