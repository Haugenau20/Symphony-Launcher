# Symphony-Launcher

A launcher for **Symphony**: an unattended orchestrator that runs an OpenCode
agent against a queue of work items, headless, until each one is ready for a
human. It pulls three images from Artifactory (`opencode`, `-squid`,
`-symphony`) and wires them together with `docker compose` — no build step,
no host repository bind, no web UI unless you ask for one.

> **Read the maintainer repo's [`docs/SYMPHONY.md`](https://github.com/Haugenau20/OpenCode-Setup/blob/claude/symphony-multi-project-scaling-7z5mug/docs/SYMPHONY.md)
> before your first real run** (see [The security model](#the-security-model) below for why).
> This README states the shape of the containment; the argument for why it
> holds lives there, and a summary is not a substitute for it.
>
> Note the branch in that URL. As of 2026-08-10 `docs/SYMPHONY.md` and
> `docs/MULTI_PROJECT.md` exist only on OpenCode-Setup's
> `claude/symphony-multi-project-scaling-7z5mug` branch and are **not** on
> `main`, so every link to them here is branch-pinned and will rot the moment
> that branch merges or is renamed. Repointing them at `main` is the first
> item in [`docs/SYNC.md`](docs/SYNC.md).

## Contents

- [What Symphony is](#what-symphony-is)
- [Why this is a separate launcher](#why-this-is-a-separate-launcher)
- [Install](#install)
- [The CLI](#the-cli)
- [Project layout](#project-layout)
- [The four env layers](#the-four-env-layers)
- [First run](#first-run)
- [What `check` catches](#what-check-catches)
- [Operational traps](#operational-traps)
- [The security model](#the-security-model)
- [What is NOT verified](#what-is-not-verified)
- [More docs](#more-docs)

## What Symphony is

Symphony is **a different way of working, not a new feature of the old
one**. The normal OpenCode workflow is one human, one local repo, one
session, torn down on exit. Symphony is the opposite of every part of that:

- **No human.** The agent runs unattended, with no one to answer a prompt.
- **No local repo.** Nothing is bind-mounted from your machine; the agent
  clones its own workspace per item, fresh, into a disposable directory.
- **Runs until stopped.** An orchestrator polls a queue on an interval and
  keeps dispatching work until you `symphony stop`, not until one task ends.

A work item is either a markdown file in a directory tree (the **file
queue**, `tracker.kind: file_queue`) or a GitLab issue carrying a
`symphony::` label (the **gitlab** tracker). Either way the item's state
*is* its position — a directory, or a label — there is no database. The
orchestrator moves an item to `review/` (or `symphony::review`) on a clean
exit and stops there; a human decides what happens next. Nothing merges,
closes, or relabels on the agent's own authority.

## Why this is a separate launcher

Symphony was ported into [Opencode-Launcher](https://github.com/Haugenau20/Opencode-Launcher)
first, then reverted (commit `3a8fa50`, reverted in `eb36763`) and moved
here instead. The revert commit is worth reading in full; the short version:

Opencode-Launcher's whole design is built around `${REPO_PATH}:/workspace` —
one human's real checkout, bind-mounted into the container so the agent can
work on it directly. The symphony port needed a host-repo argument only to
derive a project slug, and that argument fed the very same bind. The result
was an **unattended** agent with **read-write access to the developer's real
checkout**, and `/workspace` — being OpenCode's project root — sits behind
no `permission.external_directory` gate at all. That gate is what makes an
*interactive* stack safe to point at a real repo: it asks before touching
anything outside `/workspace`. Unattended means nobody is there to answer,
so the one directory with no gate is exactly the one an unattended agent
should never be able to reach.

This launcher's compose stack simply never declares that bind. `/workspace`
is an empty named volume; the agent clones each item fresh into
`/workspaces/<item>` and never reads `/workspace` at all. There is no
`<host-repo-path>` argument anywhere in this CLI — every verb takes a
**project name**, never a path (see [Project layout](#project-layout)).

## Install

```bash
git clone <this-repo> symphony-launcher
cd symphony-launcher
./symphony init <name>
```

Or run [`install.sh`](install.sh), which clones the repo (if not already
checked out), checks for Docker and the `docker compose` v2 plugin, and
prints the next commands — it does not boot anything itself. It is safe to
re-run; it never overwrites an existing checkout or `.env`.

Before the first `up`, copy [`.env.example`](.env.example) to `.env` and set
`IMAGE_REGISTRY` to your real registry path (and, for the GitLab tracker,
copy [`symphony.env.example`](symphony.env.example) to `symphony.env`).
`symphony init <name>` also copies the per-project templates from
[`projects/_example/`](projects/README.md) automatically.

## The CLI

Verb-first, always with a **project name**, never a repo path:

| Verb | What it does |
|---|---|
| `init <name>` | Scaffold `projects/<name>/{config,queue,workspaces}` and copy the per-project `.env`/`symphony.env` templates. Idempotent. |
| `check <name>` | Preflight only — creates nothing. Refuses on a missing `WORKFLOW.md`, a gitlab tracker with no token, and several other fatal misconfigurations; warns on the quieter ones. See [What `check` catches](#what-check-catches). |
| `up <name> [--publish]` | Preflight, then pull and start `opencode` + `squid` + `symphony` — headless, no port bound. `--publish` also starts the `publish` service and binds a loopback debug port; nothing binds a host port otherwise. |
| `logs <name>` | Follow the orchestrator's log. No-ops if it isn't running. |
| `status <name>` | Per-state queue counts (file queue) or the tracker's project/board (gitlab), plus whether the orchestrator is up. |
| `stop <name>` | Stop the orchestrator only. `opencode`/`squid` keep running; in-flight items resume on restart. |
| `down <name>` | Tear down the whole stack for this project. |
| `add <name> "<task>" [--id ID] [--title TITLE]` | Queue a file-queue item in `todo/`. Refuses under `tracker: gitlab` — there, work items are issues, not files. |
| `config <name>` | Print the fully resolved `docker compose config` — four env layers plus derived paths is more than you can resolve by reading files. |
| `projects` | List every project: name, tracker, published port, running state. |
| `version` / `help` | Self-explanatory. |

Tab completion for bash and zsh is in [`completions/`](completions/README.md).

## Project layout

```
projects/<name>/
├── .env             per-project, AGENT-visible   -> PROJECT_ENV_FILE
├── symphony.env     per-project, LAUNCHER-ONLY    (never handed to the agent)
├── config/
│   └── WORKFLOW.md  tracker choice, run limits, the agent's prompt — TRUSTED, read-only
├── queue/           file_queue tracker only: todo/ in-progress/ review/ done/ failed/ cancelled/
├── workspaces/      per-item agent clones — always created, whichever tracker
└── allowlist.d/     optional: this project's own squid egress allowlist
```

One checkout runs any number of projects. `config/` is a *subdirectory* of
`projects/<name>/`, one level below `symphony.env`, and that is load-bearing
rather than tidy: it is the only part of the project directory bind-mounted
into the symphony container, so the project's own credential files can
never be reachable from inside it. `symphony check` refuses to start if an
agent env file is readable from that mount. Details, including why the
split exists at all, are in [`projects/README.md`](projects/README.md).

## The four env layers

Two splits, at right angles: agent-visible vs. launcher-only, and shared vs.
per-project. Read in this order, last value wins:

| | agent-visible | launcher-only |
|---|---|---|
| shared | `.env` | `symphony.env` |
| per-project | `projects/<name>/.env` | `projects/<name>/symphony.env` |

The two **agent-visible** files (`.env`, `projects/<name>/.env`) reach the
agent's container via `docker-compose.yml`'s `env_file:` directive — every
key in either is an environment variable the agent can read. The two
**launcher-only** files reach `docker compose` only via `--env-file`, which
drives `${VAR}` interpolation and puts nothing inside a container by
itself. That distinction is the entire mechanism keeping the orchestrator's
GitLab token out of the agent's environment — see
[The security model](#the-security-model).

## First run

Start on the **file queue**, with both git gates off. This is stage 0 of
the rollout `docs/SYMPHONY.md` argues for — free, in the sense that it needs
no GitLab project, no token, and no network — and it answers the only
question that matters before any of the rest is worth building: **does your
model hold an unattended multi-turn loop at all, or does it derail at turn
four?**

```bash
./symphony init demo
cp templates/WORKFLOW.md.example projects/demo/config/WORKFLOW.md
$EDITOR projects/demo/config/WORKFLOW.md      # leave ALLOW_REMOTE_GIT=0
./symphony check demo
./symphony up demo
./symphony add demo "say hello and end with SYMPHONY_DONE"
./symphony logs demo
```

`projects/_example/.env.example` ships `ALLOW_REMOTE_GIT=0` and
`ALLOW_GITLAB_WRITE=0` for exactly this reason — the agent can commit
locally and cannot push, so the first run carries zero remote risk. Watch
the item move `todo/` -> `in-progress/` -> `review/` and read what landed
there before you touch either gate.

Once that works, **move to GitLab for real work** — the review gate becomes
a URL instead of an `ls`, and merge requests link themselves to issues:

```bash
cp templates/WORKFLOW.gitlab.md.example projects/demo/config/WORKFLOW.md
$EDITOR projects/demo/config/WORKFLOW.md      # base_url, project_id, the clone URL
echo 'SYMPHONY_GITLAB_TOKEN=<Reporter token>' >> projects/demo/symphony.env
$EDITOR projects/demo/.env                    # GITLAB_PAT (Developer), then flip both gates on
./symphony check demo
./symphony up demo
```

Read the maintainer repo's [`docs/SYMPHONY.md`](https://github.com/Haugenau20/OpenCode-Setup/blob/claude/symphony-multi-project-scaling-7z5mug/docs/SYMPHONY.md),
"Rolling this out" section, for the stages between stage 0 and production
repos — do not skip from a throwaway repo straight to one that matters.

## What `check` catches

`symphony check <name>` is a pure preflight — it changes nothing on disk.
Fatal (refuses to start): a missing `WORKFLOW.md`, a gitlab tracker with no
`SYMPHONY_GITLAB_TOKEN`, a workspaces path colliding with the queue or
config path, an agent env file readable from the symphony container's
`/config` mount, or an inline `#` comment in a launcher-only env file (the
parser does not strip trailing comments — a stray one silently becomes part
of a value). With `docker` on `PATH` it also resolves the full compose
config and asserts the Reporter token's value never appears in the
`opencode` service's block of it.

It warns (does not refuse) on the quieter mistakes: a `SYMPHONY_*` key
leaked into an agent-visible file; the same token used for symphony and the
agent; a token inherited from the shared file rather than set per-project;
`GIT_REMOTE_ALLOWLIST` and `GITLAB_WRITE_PROJECTS` disagreeing with each
other or with the tracker's own project; a `completion_marker` that never
appears in the prompt body; a non-empty `hooks.after_create`; an
`opencode.server_url` that doesn't match where the entrypoint actually
listens; a GitLab clone URL that doesn't mention `tracker.project_id`; a
tracker host missing from the egress allowlist; `stall_timeout_ms` under 10
minutes; a placeholder `IMAGE_REGISTRY`; and, for the file queue, its six
state directories not sharing one filesystem (the atomic-claim argument
depends on it — see `docs/SYMPHONY.md`, "The queue is the interface").

## Operational traps

Worth knowing *before* the first unattended run, not after:

- **`review` means the agent stopped, not that it finished.** An item
  reaching `review/` (or `symphony::review`) proves nothing about whether
  the work is done — running out of `max_turns` is a clean exit too. An
  item can land in review with no branch, no merge request, and no work at
  all, and nothing in the log shouts about it by default.
- **`max_turns` is a ceiling, not a budget.** Without a working
  `completion_marker` the loop has no exit but exhaustion: symphony owns
  the item's active/terminal state and does not move it until the run
  ends, so "is it still active?" is true on every single turn. Every run
  then burns its **entire** turn budget, and an agent looking for work to
  fill an empty turn tends to amend commits, force-push, or open a second
  merge request. `check` warns if the workflow sets a marker the prompt
  never actually asks for.
- **`stall_timeout_ms` measures run time, not stalls**, at the pinned
  orchestrator ref. It stamps the moment a run starts and nothing updates
  that stamp while the agent works, so a run is killed once it has simply
  been *alive* this long — however much progress it is making. Too low a
  value kills anything that clones a repository before it gets anywhere.
- **Nothing watches merge-request state.** A merged MR does not move its
  item to `done` on its own, and does not reclaim its workspace. `review ->
  done` is yours to make, deliberately — see `docs/SYMPHONY.md`, "Workspaces
  are reclaimed, eventually."

## The security model

This launcher does not repeat the security argument here, on purpose. The
containment that actually holds is a specific, load-bearing shape:

- **Two tokens, two different roles.** The agent's GitLab credential
  (`GITLAB_PAT`, Developer role) can push code and cannot touch the issue
  queue's state. The orchestrator's credential (`SYMPHONY_GITLAB_TOKEN`,
  Reporter role) can read and write issues and cannot push code. Neither
  can do the other's job.
- **Credential absence removes capability.** Every MCP server in the image
  auto-enables the moment its full credential set is present — a blank in
  `projects/<name>/.env` keeps a service out of that project's stack
  entirely, not merely disabled.
- **The allowlists (`GIT_REMOTE_ALLOWLIST`, `GITLAB_WRITE_PROJECTS`) are
  defence in depth, not a boundary.** The agent has bash and can call
  `/usr/bin/git` directly, past any PATH shim. The boundary is the token's
  project scope and its role, not a list of prefixes.
- **`WORKFLOW.md` is trusted config, mounted read-only.** It drives the
  hooks and is the only safe source for a clone URL. Queue items, issue
  descriptions, and issue comments are hostile input by construction —
  writable by the agent that ran before you, and on GitLab, by anyone with
  project access.

Every one of those four claims has a load-bearing argument behind it in the
maintainer repo's [`docs/SYMPHONY.md`](https://github.com/Haugenau20/OpenCode-Setup/blob/claude/symphony-multi-project-scaling-7z5mug/docs/SYMPHONY.md)
— why a personal PAT is disqualifying, why `api` scope means nothing
without the Reporter/Developer role split, what actually breaks if the two
allowlist gates disagree, and what an issue-borne "clone from here first"
actually is. **Read it before you point a project at anything that
matters.** A paraphrase that says "it's sandboxed and uses scoped tokens"
produces confidence with none of the reasoning that makes the confidence
conditional — that document argues its case; this README is not a
substitute for the argument, only a map of where the load-bearing pieces
sit in this repo. [`docs/MULTI_PROJECT.md`](https://github.com/Haugenau20/OpenCode-Setup/blob/claude/symphony-multi-project-scaling-7z5mug/docs/MULTI_PROJECT.md)
covers the compose contract this launcher implements a port of.

## What is NOT verified

Be plain about this rather than reassuring about it:

- **This stack has never been booted.** The three images live in a private
  Artifactory, and the `-symphony` image may not be published in your
  registry at all yet — the maintainer repo's release that publishes it
  may not have been cut. **A pull failure on it is an expected state, not
  a bug in this launcher.** Everything in this repo has been verified at
  `docker compose config` level — the resolved environment, the resolved
  volumes, the resolved credential placement — and those are real checks,
  but none of them is a boot.
- **The GitLab integration has never touched a live API.** The maintainer
  repo's own docs record that `GitLabTracker` and all six MCP write tools
  (`create_merge_request`, `update_merge_request`, `create_mr_note`,
  `create_issue`, `create_issue_note`, `update_issue_note`) are unit-tested
  against mocks only. Assume the first real run against a real GitLab
  project finds bugs; `docs/SYMPHONY.md`'s "What to expect when it breaks"
  section is written with that assumption built in, and so is
  [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) here.

## More docs

- [`docs/SYNC.md`](docs/SYNC.md) — what has to stay in step with the
  maintainer repo (OpenCode-Setup), so a change there gets mirrored here
  deliberately instead of discovered later.
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — what to look at
  when a run breaks, in rough order of likelihood.
- [`projects/README.md`](projects/README.md) — the per-project layout and
  the four config layers, in more depth.
- [OpenCode-Setup](https://github.com/Haugenau20/OpenCode-Setup) — the
  maintainer repo. It owns the images, the orchestrator vendoring, and
  `docs/SYMPHONY.md`.
