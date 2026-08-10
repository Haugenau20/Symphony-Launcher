# Symphony-Launcher

Run a coding agent unattended against a queue of work.

An orchestrator watches a queue, and for each item it starts an agent in a
container, hands it an empty workspace, and lets it work until it either
finishes or runs out of turns. The result is parked for a human to review.
Nobody sits in front of it; there is no prompt to answer and nothing to
attach to.

This repository is the launcher: it holds the compose stack, the
configuration layers, and a preflight that refuses to start a deployment
that is misconfigured in one of the ways that only becomes visible hours
later.

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [The CLI](#the-cli)
- [Project layout](#project-layout)
- [Configuration: four layers](#configuration-four-layers)
- [WORKFLOW.md](#workflowmd)
- [Your first run](#your-first-run)
- [The security model](#the-security-model)
- [What `check` catches](#what-check-catches)
- [Operational traps](#operational-traps)
- [What is not verified](#what-is-not-verified)

## How it works

Three containers per project:

| | |
|---|---|
| `opencode` | the agent. Runs the actual work, one session per item. |
| `symphony` | the orchestrator. Polls the queue, dispatches, moves items between states. |
| `squid` | the only route off the host. Everything else is on an internal network. |

A **work item** is either a markdown file in a directory tree (the *file
queue*) or a GitLab issue carrying a `symphony::` label (the *gitlab*
tracker). Either way, **the item's state is its position** — which directory
it sits in, or which label it carries. There is no database and no status
field, which is why `ls` is the dashboard and `mv` is how you move a card.

The loop, per item:

1. The orchestrator claims the item and creates an **empty** directory for
   it under `workspaces/<id>/`.
2. It starts one agent session and sends it the prompt from `WORKFLOW.md`.
   The agent's first job is to clone the repository it will work on — the
   orchestrator deliberately does not do this for it (see
   [The security model](#the-security-model)).
3. Turns 2..`max_turns` continue that *same* session, so context
   accumulates. The run ends early when the agent emits a completion
   marker.
4. On a clean exit the item moves to `review`, and stops there.

**`review` is a human gate.** Nothing moves an item out of it but you.

## Requirements

- Docker, with the `docker compose` v2 plugin
- Bash
- Access to a container registry holding the three images this stack runs:
  `${IMAGE_REGISTRY}`, `${IMAGE_REGISTRY}-squid` and
  `${IMAGE_REGISTRY}-symphony`

This launcher is **pull-only** — it never builds an image, and there is no
`build:` block in any of its compose files. It runs what your registry
already has, at the tag you set in `IMAGE_TAG`.

> If `docker compose pull` fails on the `-symphony` image specifically, the
> most likely explanation is that your registry does not carry that tag yet
> rather than anything wrong with your configuration. It is published
> separately from the other two.

## Quick start

```bash
git clone <this-repo> symphony-launcher
cd symphony-launcher

cp .env.example .env
$EDITOR .env                       # IMAGE_REGISTRY, LLM endpoint, git identity

./symphony init demo               # scaffold projects/demo/
cp templates/WORKFLOW.md.example projects/demo/config/WORKFLOW.md
$EDITOR projects/demo/config/WORKFLOW.md

./symphony check demo              # preflight — changes nothing
./symphony up demo
./symphony logs demo
```

[`install.sh`](install.sh) does the clone and checks your Docker setup, if
you would rather start there. It boots nothing itself and is safe to re-run.

## The CLI

Every verb takes a **project name**:

| Verb | What it does |
|---|---|
| `init <name>` | Scaffold `projects/<name>/` and copy the per-project config templates. Idempotent — never overwrites. |
| `check <name>` | Preflight only. Creates nothing. See [What `check` catches](#what-check-catches). |
| `up <name> [--publish]` | Preflight, pull, start. Headless: nothing binds a host port unless you pass `--publish`. |
| `logs <name>` | Follow the orchestrator's log. |
| `status <name>` | Queue counts (file queue) or the tracker's board (gitlab), and whether the orchestrator is up. |
| `stop <name>` | Stop the orchestrator; leave the agent stack running. In-flight items resume on restart. |
| `down <name>` | Tear the whole stack down. |
| `add <name> "<task>"` | Queue a file-queue item. Takes `--id` and `--title`. |
| `config <name>` | Print the fully resolved compose configuration. |
| `projects` | List every project: name, tracker, port, running state. |
| `version`, `help` | |

`config` earns its place: with four configuration layers plus derived paths,
"what did this actually resolve to" is a question best answered by the thing
that did the resolving.

Shell completions for bash and zsh are in
[`completions/`](completions/README.md).

## Project layout

One checkout runs any number of projects, each fully independent:

```
projects/<name>/
├── .env             the AGENT's environment — credentials it may use
├── symphony.env     the ORCHESTRATOR's environment — never reaches the agent
├── config/
│   └── WORKFLOW.md  tracker, run limits, and the agent's prompt
├── queue/           file queue only: todo/ in-progress/ review/ done/ failed/ cancelled/
├── workspaces/      one disposable directory per item
└── allowlist.d/     optional: this project's own egress allowlist
```

`config/` is a **subdirectory**, one level below `symphony.env`, and that is
load-bearing rather than tidy. `config/` is the only part of the project
directory mounted into the orchestrator's container, so nothing
credential-bearing may sit in it. Putting `symphony.env` beside
`WORKFLOW.md` instead of above it would hand the orchestrator's own
credential file into a mount that has no business carrying one. `check`
refuses to start if it finds an agent environment file readable from there.

The six queue directories must share one filesystem. Claiming an item is a
`rename(2)` between them, which is atomic only within a single filesystem —
that atomicity is the entire locking story, so `check` verifies the six
really are on one device rather than assuming it.

## Configuration: four layers

Two distinctions, at right angles. Read in this order, last value wins:

| | reaches the agent | launcher only |
|---|---|---|
| **shared** | `.env` | `symphony.env` |
| **per-project** | `projects/<name>/.env` | `projects/<name>/symphony.env` |

The left column is handed to the agent's container wholesale by an
`env_file:` directive — **every key in either file is an environment
variable the agent can read.** The right column is only ever passed to
`docker compose` as `--env-file`, which drives `${VAR}` substitution in the
compose files and by itself puts nothing inside any container. The
orchestrator's credential reaches its own container through that service's
`environment:` block and no other path.

That is not a filing convention. It is the mechanism, and it is why
`symphony.env` and `.env` are separate files rather than one file with a
comment in it.

Per-project paths (queue, workspaces, config) are **derived** from
`projects/<name>/` rather than being settable in a shared file. A shared
default for any of them would quietly point two projects at one queue, and
two orchestrators claiming the same item is the one thing the atomic-claim
argument above assumes cannot happen.

**Blank a credential to remove it.** Every service in the agent's image
switches on when its credentials are present, so an explicit empty
assignment in a project's `.env` keeps that service out of the stack
entirely:

```sh
CONFLUENCE_PAT=
JIRA_PAT=
```

Empty means *absent*, not disabled. A key you merely leave out is inherited
from the shared file instead — which is the opposite of what you wanted.

## WORKFLOW.md

One per project, and the whole of its configuration: which tracker, the run
limits, and the prompt the agent receives. Two templates ship in
[`templates/`](templates/) — one per tracker.

It is mounted **read-only**, and that is deliberate. `WORKFLOW.md` is
*trusted* input: it drives the hooks and it is the only safe place a clone
URL can come from. Work items are not trusted — a queue file is written by
the agent that ran before you, and a GitLab issue is writable by anyone with
project access. Never template a hook from item content, and keep
`WORKFLOW.md` in a directory containing nothing else worth reading.

Three settings deserve attention before a first run — `max_turns`, the
completion marker, and `stall_timeout_ms`. See
[Operational traps](#operational-traps) for why each one bites.

## Your first run

**Start on the file queue, with both git gates off.** It needs no tracker
project, no token and no network, so it costs nothing — and it answers the
question everything else depends on: *does your model hold an unattended,
multi-turn loop at all, or does it derail at turn four?* If the answer is
no, nothing downstream is worth configuring.

```bash
./symphony init demo
cp templates/WORKFLOW.md.example projects/demo/config/WORKFLOW.md
./symphony check demo
./symphony up demo
./symphony add demo "say hello, then end your reply with SYMPHONY_DONE"
./symphony logs demo
```

The shipped project template sets `ALLOW_REMOTE_GIT=0` and
`ALLOW_GITLAB_WRITE=0` for exactly this reason: the agent can commit locally
and cannot push, so a first run carries no remote risk at all. Watch an item
move `todo/` → `in-progress/` → `review/`, and read what actually landed
there before you turn either gate on.

**Then move to GitLab for real work.** The review gate becomes a URL you can
open from anywhere instead of an `ls` on one machine, and merge requests
link themselves to their issues.

```bash
cp templates/WORKFLOW.gitlab.md.example projects/demo/config/WORKFLOW.md
$EDITOR projects/demo/config/WORKFLOW.md   # base_url, project_id, and the clone URL
echo 'SYMPHONY_GITLAB_TOKEN=<Reporter token>' >> projects/demo/symphony.env
$EDITOR projects/demo/.env                 # GITLAB_PAT (Developer), then the two gates
./symphony check demo
```

Create the six state labels on the project first — `symphony::todo`,
`symphony::in-progress`, `symphony::review`, `symphony::done`,
`symphony::failed`, `symphony::cancelled`. An issue carrying none of them is
not the orchestrator's and is ignored, which is how an ordinary backlog
lives in the same project.

Widen slowly after that: a sandbox project first, then a couple of
low-stakes real ones. Raise `max_turns` before you raise concurrency — turns
tell you whether the model can finish, concurrency only multiplies whatever
it already does.

## The security model

The agent runs unattended, with a shell, and it has to push branches and
open merge requests to be useful at all. So it matters which parts of this
are actually load-bearing and which are only tidy.

### The token's scope is the boundary

**Do not give this a personal access token.** A personal token carries your
whole identity — every group and every production repository you can reach —
and nothing inside the container can claw that back, because the token *is*
the authority. Constraining an agent that holds one is not possible; you can
only ask it nicely.

Use the narrowest credential that does the job: a **project access token**,
scoped to the single project the deployment works on. Every other project
then returns 404 — not "denied", invisible. A confused agent, a hallucinated
remote, or an instruction injected through an issue comment all hit a
server-side authorization check that does not read English and cannot be
argued with.

Then, server-side and free: protect the default branch so nothing can push
to it directly, require an approval, and grant Developer rather than
Maintainer so the token cannot change project settings or delete
repositories.

### Two tokens, neither able to do the other's job

| | Role | Can push code? |
|---|---|---|
| the orchestrator (`SYMPHONY_GITLAB_TOKEN`) | **Reporter** | **No** |
| the agent (`GITLAB_PAT`) | **Developer** | Yes — that one project |

The orchestrator reads and writes issues. The agent pushes branches and
opens merge requests. Neither can do the other's job, so a compromised
orchestrator can vandalise issue text and nothing else, and a prompt-injected
agent **cannot rewrite its own work queue** — it cannot mark its own work
reviewed, and it cannot queue itself more.

Be precise about what constrains what: API scope is not the control here.
There is no issues-only scope; `api` is full API access for that project. It
is the **Reporter role** that stops the orchestrator pushing code. Effective
permission is scope × role, so get the role right.

This is why the two credentials live in separate files, and why `check`
*refuses* to start when it finds one token doing both jobs. With a single
credential there is nothing left to contain: either it is Reporter and the
agent cannot push, or it is Developer and the orchestrator can — and an agent
holding it can relabel its own issue.

### Credential absence removes capability

Every integration in the agent's image switches on when its credentials are
present. So a deployment should carry only what it needs and blank the rest
explicitly. A blanked integration is never wired up at all: absent, not
disabled, with no switch for the agent to find.

### The allowlists are defence in depth, not a boundary

`GIT_REMOTE_ALLOWLIST` narrows where git may push; `GITLAB_WRITE_PROJECTS`
narrows which projects the API write tools will act on. Both are worth
setting. **Neither is a security boundary**, and it is important not to
mistake them for one: the agent has a shell and can call `/usr/bin/git`
directly, past any wrapper on `PATH`, or `curl` the API itself.

What they buy is legibility — they turn a mistake into a clear local error
instead of a confusing 403 an hour later. The boundary is the token's
project scope and its role. Do not let an allowlist talk you into a broader
token.

The two are read by different processes gating different protocols, so
nothing at runtime can make them agree with each other. `check` cross-checks
them, because a mismatch otherwise surfaces mid-run as an agent that pushed
a branch it cannot open a merge request for.

### The agent clones its own workspace

The orchestrator creates an empty directory and stops there. It does not
clone, and this is not an oversight: cloning would require a repository
credential in the orchestrator's container, which is the one container that
deliberately holds nothing but an issue-tracker token.

So the clone is the agent's first step, and **the prompt has to tell it
so** — an empty directory with no instruction is just an agent with no code.
Both shipped templates carry that instruction, and the URL lives in
`WORKFLOW.md` because that is the only file in the loop that an attacker
cannot write to. "Clone from … first" appearing inside an issue is an
attack, not an instruction.

### Egress

The orchestrator reaches a tracker through the proxy and nothing else. Both
of its networks are internal, so the proxy is the only way out, and the
route is derived from the tracker you configured rather than being a setting
you fill in — on the file queue it has no egress at all, holds no
credentials, and only moves files.

### Nothing binds your working copy

No host repository is mounted into the agent's container by this stack, and
none can be: the agent's project root is an empty volume, and every item is
worked in a fresh clone under `workspaces/`. An unattended agent operating
on a real checkout is not a risk worth carrying for a convenience nobody is
present to use.

## What `check` catches

`symphony check <name>` is a pure preflight that changes nothing on disk.
It exists because an unattended misconfiguration does not announce itself at
a prompt — it surfaces as an agent doing something unintended, hours later.

**Refuses to start** on: a missing `WORKFLOW.md`; a gitlab tracker with no
orchestrator token; one token configured for both roles; a workspaces path
colliding with the queue or config path; an agent environment file readable
from the orchestrator's `/config` mount; an inline `#` comment in a
launcher-only environment file (nothing strips it, so it silently becomes
part of the value). With `docker` available it also resolves the whole
compose configuration and asserts the orchestrator's token never appears
anywhere in the agent service.

**Warns** on the quieter mistakes: a `SYMPHONY_*` key left in a file the
agent can read; a token inherited from the shared file rather than set
per-project; the two allowlists disagreeing with each other or with the
tracker's own project; a completion marker the prompt never asks for; a
non-empty `after_create` hook; a server URL that does not match where the
agent actually listens; a clone URL that does not mention the tracker's
project; a tracker host missing from the egress allowlist; a stall timeout
too short to survive a clone; a placeholder registry; more than one agent at
a time before you have watched a full run; and the six queue directories not
sharing a filesystem.

Run it after editing any configuration file. It is cheap, and every one of
those is expensive to debug from the other end.

## Operational traps

Worth knowing *before* the first unattended run:

- **`review` means the agent stopped, not that it finished.** An item
  reaches `review` on a clean exit — and running out of turns is a clean
  exit. An item can arrive there with no branch, no merge request and no
  work at all. Check what landed; do not assume.
- **`max_turns` is a ceiling, not a budget.** Without a working completion
  marker the loop has no exit but exhaustion, because the orchestrator owns
  the item's state and does not move it until the run is over — so "is this
  still active?" is true on every turn. Every run then spends its whole
  budget, and an agent looking for work to fill an empty turn tends to amend
  commits, force-push, or open a second merge request. Raising `max_turns`
  makes that worse, not better. The marker is what makes a generous ceiling
  safe; `check` warns if you set one the prompt never asks for.
- **`stall_timeout_ms` measures run time, not stalls.** It stamps the moment
  a run starts, so a run is killed once it has simply been *alive* that long,
  however much progress it is making. Anything that clones a repository
  needs far more than the default.
- **Nothing watches merge-request state.** A merged merge request does not
  move its item to `done`, and does not reclaim its workspace. `review →
  done` is a human decision by construction — that is the design, not a gap.

## What is not verified

Stated plainly rather than reassuringly:

- **This stack has not been booted.** Everything here is verified at the
  level of resolved compose configuration — the resolved environment, the
  resolved mounts, and where each credential ends up. Those are real checks
  and the test suite runs them against the real resolver, but none of them
  is a boot.
- **The GitLab integration has not run against a live API.** The tracker and
  the API write tools are tested against mocks. Assume the first real run
  finds bugs, and point it at a project you would not mind losing.

## More docs

- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — what breaks first, and how to tell the causes apart
- [`docs/IMAGE_CONTRACT.md`](docs/IMAGE_CONTRACT.md) — the interface between this launcher and the images it runs
- [`projects/README.md`](projects/README.md) — the per-project layout in detail
- [`CHANGELOG.md`](CHANGELOG.md)
