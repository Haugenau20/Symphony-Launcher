# The image contract

This launcher does not build the images it runs — it only assembles compose
files, resolves environment layers, and starts what a registry already has
(see the README's Requirements section). That split means there is a real
interface between the two halves: variables this launcher must set for an
image to behave, and structural properties of the compose stack that the
images assume will stay true. This document is that interface, stated from
the launcher's side.

Everything here is either read by `lib/symphony.sh`/`lib/commands.sh` when
resolving a stack, or asserted by `symphony check`. If you change one of
these and `check` or the test suite does not immediately object, that is a
gap in the check, not evidence the change was safe.

## The environment contract

Each row is a variable this launcher sets (directly or by derivation) and
the one component on the other side that actually reads it.

| Variable | Set by | Consumed by |
|---|---|---|
| `SYMPHONY_QUEUE_ROOT` | fixed at `/queue` in `docker-compose.symphony.yml`'s `symphony` service | the orchestrator: the in-container root of the six file-queue state directories |
| `SYMPHONY_WORKSPACES_ROOT` | fixed at `/workspaces` in the same block | the orchestrator: where it creates a per-item directory and hands the path to the agent's prompt |
| `SYMPHONY_WORKFLOW` | fixed at `/config/WORKFLOW.md` | the orchestrator's config loader — the one file that defines tracker choice, run limits, and the agent's prompt |
| `SYMPHONY_OPENCODE_URL` | `http://opencode:${OPENCODE_INTERNAL_PORT:-4096}`, derived in `docker-compose.symphony.yml` | the orchestrator entrypoint's readiness wait. It must track the *internal* port, never a host-published one — see the invariant below |
| `SYMPHONY_GITLAB_TOKEN` | `projects/<name>/symphony.env` (or the shared `symphony.env`), reaching a container only through the `symphony` service's own `environment:` block | the orchestrator's GitLab tracker. Never reaches the agent — see the invariant below |
| `SYMPHONY_LOG_LEVEL` | `symphony.env` / `projects/<name>/symphony.env`, default `info` | the orchestrator's logger |
| `OPENCODE_EXTRA_ALLOWED_DIRS` | fixed at `/workspaces/**` in `docker-compose.yml`'s `opencode` service `environment:` | opencode's `permission.external_directory` gate. Unattended means nobody can answer an "ask" prompt, so this is set directly in `environment:` (which outranks `env_file:`) rather than left to a project's `.env`, which could widen it |
| `PROJECT_ENV_FILE` | derived by `symphony_derive_settings` (`lib/symphony.sh`) from `projects/<name>/.env`, passed to the `opencode` service's `env_file:` | compose's `env_file:` layering — the per-project file that wins last over the shared `.env` |
| `EXTRA_ALLOWLIST_PATH` | derived the same way, exported only when `projects/<name>/allowlist.d/` exists | the `squid` service's mount, `${EXTRA_ALLOWLIST_PATH:-./extra-allowlist.d}:/etc/squid/extra-allowlist.d:ro,z` |
| `PROJECT_SLUG` + the compose `-p symphony-<name>` project name | `symphony_derive_settings`, exported and passed as `-p` on every `docker compose` invocation | container and volume naming (`${PROJECT_SLUG:-default}` throughout both compose files) and compose's own project isolation — without a distinct `-p`, `up` on one stack treats another stack's containers as orphans to remove |
| `ALLOW_REMOTE_GIT` / `GIT_REMOTE_ALLOWLIST` | `.env` / `projects/<name>/.env`, read through the `env_file:` layers, deliberately **not** repeated in `environment:` | the image's git-guard `PATH` shim (the git plane) |
| `ALLOW_GITLAB_WRITE` / `GITLAB_WRITE_PROJECTS` | same files, same layering | the GitLab MCP's write-tool gate (the API plane) |

The last two are read by different processes gating different protocols, so
nothing at runtime makes them agree with each other. `symphony check`
cross-checks them, because a mismatch otherwise surfaces mid-run as an agent
that pushed a branch it cannot open a merge request for.

## Invariants the compose stack must keep

These are properties of `docker/docker-compose*.yml` that later edits must
not break, each with the reason it matters. `symphony check`'s
resolved-config cross-check enforces some of these directly; the rest are
enforced only by not touching them.

**`:z`, never `:Z`, on shared bind mounts.** The same host directory (e.g.
`extra-allowlist.d/`) is mounted across more than one project's stack. `:Z`
relabels a mount as exclusive to one container, which would break every
other project sharing it; `:z` relabels it as shared. Named volumes need
neither — they are auto-labelled.

**`/config` is mounted read-only.** `WORKFLOW.md` is trusted input: it
drives the hooks and is the only safe place a clone URL can come from
(README, "WORKFLOW.md"). A writable mount would let anything running inside
the orchestrator's container rewrite the file that configures it.

**The compose SERVICE names `opencode`, `squid`, and `symphony` are
load-bearing and must never be renamed**, even though their *container*
names are freely `symphony-<slug>-*`. The orchestrator dials the literal
hostname `opencode` on an internal network, and `WORKFLOW.md`'s
`opencode.server_url` has to say the same thing by hand — `symphony_preflight`
in `lib/symphony.sh` is what catches a drift between the two. Renaming the
service (as opposed to the container) breaks the orchestrator's ability to
reach it at all. The `publish` service is the one exception: nothing dials
it by name, so it may be renamed freely.

**`SYMPHONY_OPENCODE_URL` follows the INTERNAL port, never a host-published
one.** It is a container-to-container URL on an internal network
(`http://opencode:${OPENCODE_INTERNAL_PORT:-4096}`), so whether `--publish`
is in play, and what host port it chose, is irrelevant to it. Pointing it at
a published port instead would make the orchestrator's readiness wait depend
on a debug feature that is off by default.

**`SYMPHONY_GITLAB_TOKEN` reaches a container only through the `symphony`
service's own `environment:` block, never through an `env_file:` directive.**
That block is the *only* place in the whole stack the token is named.
`docker-compose.yml`'s `opencode` service gets `.env` and
`projects/<name>/.env` wholesale via `env_file:`; the token is in neither
file, so the agent's container cannot read it by construction, not by
convention. `symphony check` cross-checks the resolved `docker compose
config` for exactly this: the token's value must never appear in the
`opencode` service's block.

**Pull-only: no `build:` block anywhere, ever.** Every image is fetched from
`${IMAGE_REGISTRY}...:${IMAGE_TAG}`. Adding a `build:` block to work around a
missing registry tag would silently change what "this stack" means from "a
released, addressable image" to "whatever happens to build locally right
now" — the opposite of a reproducible unattended deployment.

**The publish overlay's dual-`socat` block must match its two published
ports.** `docker-compose.publish.yml` runs two independent `socat` legs — one
forwarding the opencode API port, one forwarding the derived viewer port
(`1<port>`) — and publishes exactly those two ports, loopback-only. If the
`socat` commands and the `ports:` mapping drift apart, one leg either fails
to bind or forwards traffic nothing is listening for. The
`trap 'kill 0' TERM INT` plus backgrounding-and-`wait` wrapper around both
legs exists so `docker stop`/`compose down` tears down both children
promptly instead of leaving them running until the container's own kill
timeout.
