# Keeping this launcher in sync with the maintainer repo

This launcher's `docker/docker-compose*.yml` are **close relatives** of
[OpenCode-Setup](https://github.com/Haugenau20/OpenCode-Setup)'s. The
images, the orchestrator vendoring (`symphony-queue`, pinned at
`SYMPHONY_REF`), and the upstream fix tracking all live there; this repo
only changes *how the stack is launched and presented*, and it is
**pull-only** — it never builds `opencode`, `squid`, or `-symphony`, and no
`build:` block may be added to work around a missing tag (see the header of
[`docker/docker-compose.symphony.yml`](../docker/docker-compose.symphony.yml)).

The two compose sets are structured differently on purpose — the maintainer
repo's single-project, build-capable stack versus this repo's multi-project,
pull-only one — so they are **not** byte-for-byte identical files. What has
to stay in step is the *behavior* the sections below describe. When you
touch compose in either repo, walk this list and mirror the runtime-relevant
change into the other.

## First: the branch-pinned links to the maintainer repo

Every link from this repo to `OpenCode-Setup/docs/SYMPHONY.md` and
`docs/MULTI_PROJECT.md` is pinned to the branch
`claude/symphony-multi-project-scaling-7z5mug`, because as of **2026-08-10**
that is the only place those two files exist — they are **not on `main`**, and
a link to `blob/main/docs/SYMPHONY.md` 404s today. Verified with
`git cat-file -e origin/main:docs/SYMPHONY.md`, which fails.

This is the most perishable thing in this repo: the moment that branch merges
or is renamed, every one of those links breaks in the other direction.

```sh
# when the branch lands on main, repoint them:
grep -rln 'OpenCode-Setup/blob/claude/symphony-multi-project-scaling-7z5mug' . \
  | xargs sed -i 's|OpenCode-Setup/blob/claude/symphony-multi-project-scaling-7z5mug|OpenCode-Setup/blob/main|g'
```

Affected today: [`../README.md`](../README.md) (4 links) and
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) (1).

The same caveat applies to the launcher's own reference points below: they
were read from that branch, not from `main`, so "matches the maintainer repo"
throughout this document means *matches that branch*.

## 1. Must match the maintainer repo

**The symphony service's `environment:` and `volumes:` blocks.** Both must
express the same contract as OpenCode-Setup's `docker-compose.symphony.yml`:
`SYMPHONY_QUEUE_ROOT=/queue`, `SYMPHONY_WORKSPACES_ROOT=/workspaces`,
`SYMPHONY_WORKFLOW=/config/WORKFLOW.md`, the two-token split
(`SYMPHONY_GITLAB_TOKEN` reaching the container only through this service's
own `environment:` block, never through an `env_file:` directive), and the
egress derivation (`HTTP_PROXY`/`HTTPS_PROXY` from `SYMPHONY_HTTP_PROXY`,
which is empty unless `tracker.kind: gitlab`). Verified here by reading
[`docker/docker-compose.symphony.yml`](../docker/docker-compose.symphony.yml)
against the maintainer repo's equivalent file — the comments differ (this
repo documents the pull-only/multi-project deltas inline) but every
`environment:`/`volumes:` key and its default matches in effect.

**The `:z` SELinux relabels.** Shared (`:z`), never private (`:Z`) — the
same host directory (e.g. `extra-allowlist.d/`) is mounted across more than
one project's stack, and `:Z` would make each mount exclusive and break the
others. `grep -rn ':Z' docker/` returns nothing in this repo; every relabel
in [`docker/docker-compose.yml`](../docker/docker-compose.yml) and
[`docker/docker-compose.symphony.yml`](../docker/docker-compose.symphony.yml)
is `:z`.

**The read-only `/config` mount.** `docker-compose.symphony.yml` mounts
`${SYMPHONY_CONFIG_PATH:-./projects/default/config}:/config:ro,z` —
`ro` because `WORKFLOW.md` is trusted config that drives the hooks, and the
agent must never be able to rewrite the thing that prompts it. Confirmed
present in this repo's copy.

**`SYMPHONY_OPENCODE_URL` following the INTERNAL port.** It must track
`OPENCODE_INTERNAL_PORT`, never a host-published port —
`SYMPHONY_OPENCODE_URL: http://opencode:${OPENCODE_INTERNAL_PORT:-4096}` in
this repo's `docker-compose.symphony.yml`. This is a container-to-container
URL on an internal network, so host publication (`OPENCODE_PORT`, opt-in via
`up --publish`) is irrelevant to it. `WORKFLOW.md`'s `opencode.server_url`
has to say the same thing by hand — `symphony_preflight` in
[`lib/symphony.sh`](../lib/symphony.sh) is what catches a drift between the
two.

**The publish service's dual-socat/viewer-port block.** (Called `oc-publish`
in the maintainer repo and in Opencode-Launcher; this repo's own service is
named `publish` — see §3's naming note.) The two `socat` legs (one for the
opencode API, one for the opencode-pty viewer on `1<port>`), the
`trap 'kill 0' TERM INT` + backgrounding + `wait` shell wrapper, and the
`PTY_WEB_HOSTNAME`/`PTY_WEB_PORT` environment lines on the `opencode`
service must stay behaviorally identical to the maintainer repo's —
otherwise the publisher either fails to bind the second port, or forwards
it to a host/port the opencode-pty server was never told to listen on.
Present in this repo in
[`docker/docker-compose.publish.yml`](../docker/docker-compose.publish.yml).

**`templates/WORKFLOW{,.gitlab}.md.example`.** Currently **byte-for-byte
identical** to the maintainer repo's `symphony/WORKFLOW.md.example` and
`symphony/WORKFLOW.gitlab.md.example` — verified with `diff` against a
checkout of OpenCode-Setup on 2026-08-10 (`diff` returned no output for
either file). These are the agent-facing prompt templates and the front
matter that drives run limits; any change to either in the maintainer repo
should be diffed against this repo's copy the same way before the next
release here, and this line updated with the new verification date.

## 2. Shared env-var contracts (launcher sets, image/orchestrator consumes)

Behavioral contracts, not blocks to diff line-for-line — this launcher
produces the value, symphony-queue or the opencode image's entrypoint
consumes it. Keep the name and semantics in sync across both repos.

| Variable | Set where | Consumed by |
|---|---|---|
| `OPENCODE_EXTRA_ALLOWED_DIRS` | `docker-compose.yml`, `opencode` service `environment:`, fixed to `/workspaces/**` | opencode's `permission.external_directory` gate. Unattended means nobody can answer an "ask" prompt, so this is set directly in `environment:` (which outranks `env_file:`) rather than left to an env file a project could widen. |
| `SYMPHONY_QUEUE_ROOT` / `SYMPHONY_WORKSPACES_ROOT` / `SYMPHONY_WORKFLOW` / `SYMPHONY_OPENCODE_URL` | `docker-compose.symphony.yml`, `symphony` service `environment:` | the orchestrator entrypoint — fixed in-container paths (`/queue`, `/workspaces`, `/config/WORKFLOW.md`) plus the readiness-wait URL. |
| `SYMPHONY_GITLAB_TOKEN` | `projects/<name>/symphony.env` (or the shared `symphony.env`), reaching the container only via the `symphony` service's own `environment:` block | symphony-queue's GitLab tracker. Never reaches the agent's container — see §1's two-token split. |
| `SYMPHONY_LOG_LEVEL` | `symphony.env` / `projects/<name>/symphony.env`, default `info` | the orchestrator's logger. |
| `PROJECT_ENV_FILE` | derived by `lib/symphony.sh` (`symphony_derive_settings`) from `projects/<name>/.env`, passed to `docker-compose.yml`'s `opencode` service `env_file:` | compose's `env_file:` layering — last-wins over the shared `.env`. |
| `EXTRA_ALLOWLIST_PATH` | derived the same way, only when `projects/<name>/allowlist.d/` exists | the squid image's `docker-compose.yml` mount, `${EXTRA_ALLOWLIST_PATH:-./extra-allowlist.d}:/etc/squid/extra-allowlist.d:ro,z`. |
| `PROJECT_SLUG` + the compose `-p symphony-<name>` name | `symphony_derive_settings`, exported and passed as `-p` on every `docker compose` invocation | container/volume naming (`${PROJECT_SLUG:-default}` throughout both compose files) and compose's own project-isolation (`-p` — without it, `up` on one stack treats another's containers as orphans to remove). |
| `ALLOW_REMOTE_GIT` / `GIT_REMOTE_ALLOWLIST` | `.env` / `projects/<name>/.env`, read through the `env_file:` layers, deliberately **not** repeated in `environment:` | the opencode image's git-guard PATH shim (the git plane). |
| `ALLOW_GITLAB_WRITE` / `GITLAB_WRITE_PROJECTS` | same files, same layering | the GitLab MCP's write-tool gate (the API plane). |

## 3. Intentional deltas — not to be mirrored back

- **Pull-only.** No `build:` block anywhere in this repo's compose files, no
  `SYMPHONY_REF`/`SYMPHONY_REPO` build args, no `symphony-dev` source-mount
  overlay. The maintainer repo builds all three images from source trees
  that simply do not exist in this checkout; adding a `build:` block here to
  work around a missing registry tag would be re-inventing what
  `release.sh` over there is for.
- **No host-repo bind at all.** The maintainer repo's symphony overlay has
  to *override* the base stack's `${REPO_PATH}:/workspace` mount by target,
  because that base stack is shared with the interactive launcher. This
  repo has no such base to override — `docker-compose.yml` here is the
  unattended agent substrate from the start and simply never declares a
  host-repo mount. See the file's own header and the README's "Why this is
  a separate launcher" section for why that is a fix, not a stylistic
  choice.
- **Container/compose-project naming is `symphony-<name>-*`, not
  `opencode-*`.** Deliberate, so both this launcher and Opencode-Launcher
  can run stacks for the same project **name** on one machine without
  colliding. **The compose SERVICE names (`opencode`, `squid`, `symphony`)
  are unchanged and must stay so** — `SYMPHONY_OPENCODE_URL` and
  `WORKFLOW.md`'s `opencode.server_url` are both built from the literal
  hostname `opencode`, and renaming the service (as opposed to the
  container) would break the orchestrator's ability to dial it. The
  publish overlay's own service is named `publish` in this repo, not
  `oc-publish` (the name both the maintainer repo and Opencode-Launcher
  use) — a presentation-only rename with nothing depending on the literal
  string, unlike `opencode`/`squid`/`symphony` above.
- **One token used for both roles is FATAL here, not a warning.**
  `docs/SYMPHONY.md` says the preflight "warns if they match", and
  OpenCode-Setup's `scripts/symphony` does exactly that. This launcher
  refuses. The reference is a general-purpose harness where an interactive
  operator sees the warning and decides; this repo exists only to start
  unattended stacks, and with one credential doing both jobs there is no
  containment left to warn about — either it is Reporter and the agent cannot
  push (every run fails late and confusingly), or it is Developer and the
  orchestrator can push code while a prompt-injected agent holding the same
  credential can relabel its own issue. The check lives in
  `symphony_preflight` ([`lib/symphony.sh`](../lib/symphony.sh)) rather than in
  `cmd_check`'s resolved-config cross-check, so the verdict does not depend on
  whether `docker` happens to be installed. **If the reference ever promotes
  this to fatal too, this delta disappears** — until then, do not "fix" the
  divergence by downgrading it.
- **No publisher by default.** `docker-compose.publish.yml` is an opt-in
  third file, added only by `up --publish`. An unattended stack has no web
  UI worth exposing to anyone by default.
- **Per-project paths are derived from `projects/<name>/`, never settable
  in a shared file.** `symphony.env.example` and the shared root
  `symphony.env` deliberately carry no `SYMPHONY_QUEUE_PATH` /
  `SYMPHONY_WORKSPACES_PATH` / `SYMPHONY_CONFIG_PATH` — see the comment at
  the bottom of [`symphony.env.example`](../symphony.env.example). A shared
  concrete default for any of them would collapse every project onto one
  queue, and two orchestrators claiming the same item is exactly what the
  `rename(2)`-is-atomic-within-one-filesystem claim in `docs/SYMPHONY.md`
  assumes cannot happen. `symphony_derive_settings` in
  [`lib/symphony.sh`](../lib/symphony.sh) derives these from the project
  directory name instead, deliberately after the shared env layers load and
  before the per-project ones do — see that function's own header comment
  for the exact ordering argument.
- **The CLI takes a project NAME, never a host-repo path.** There is no
  `<host-repo-path>` argument anywhere in `./symphony`, unlike
  Opencode-Launcher's `start.sh`. This is the fix for the defect described
  in the README's "Why this is a separate launcher" section: a host-repo
  path existed there only to derive a slug, and it fed the very mount that
  turned into the exposure. `validate_project_name` in
  [`lib/project.sh`](../lib/project.sh) is the whole identity surface.

## 4. Verified: needs no mirroring

- **`opencode.json`/MCP-server wiring on credential presence.** Purely
  image-internal — the entrypoint decides which MCP servers to wire in
  based on which credentials are non-empty in the resolved environment.
  Nothing in this repo's compose files or `lib/*.sh` needs to know about
  that decision; it only needs to get the right values (or blanks) into
  the right env-file layer, which is `docs/SYMPHONY.md` §2 and
  `projects/_example/.env.example`'s job, not this document's.
- **squid's allowlist enforcement mechanism itself** (ACL syntax,
  `http_access` ordering) — this repo only supplies `.conf` drop-ins under
  `extra-allowlist.d/` or a project's own `allowlist.d/`; how squid parses
  and enforces them is entirely image-internal.
- **The orchestrator's internal polling/dispatch/retry logic**
  (`polling.interval_ms`, `agent.max_retry_backoff_ms`, the `rename(2)`
  claim mechanics) — this repo only supplies the six bind-mounted state
  directories and `WORKFLOW.md`'s front matter; symphony-queue's own
  `docs/DESIGN.md` in the maintainer repo's vendored copy is the source of
  truth for how it behaves internally.
