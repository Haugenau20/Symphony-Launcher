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
- [Review](#review)
- [Your first run](#your-first-run)
- [The security model](#the-security-model)
- [What `check` catches](#what-check-catches)
- [Operational traps](#operational-traps)

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
| `up <name> [--publish] [--with-review]` | Preflight, pull, start. Headless: nothing binds a host port unless you pass `--publish`. Starts the services this project actually configured — implementation, review, or both; see [Review](#review). |
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
├── .env               the AGENT's environment — credentials it may use
├── symphony.env       the ORCHESTRATOR's environment — never reaches the agent
├── review.env         the REVIEW CONTROLLER's environment — never reaches
│                       either agent; see "Review" below
├── config/
│   ├── WORKFLOW.md    tracker, run limits, and the agent's prompt
│   └── REVIEW.md      review scope, run limits, and the review agent's prompt
├── queue/             file queue only: todo/ in-progress/ review/ done/ failed/ cancelled/
├── workspaces/        one disposable directory per item
├── review-store/      review job state (durable, review only)
├── review-workspaces/ one disposable directory per merge request under review
└── allowlist.d/       optional: this project's own egress allowlist
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

## Review

A second, independent pipeline: instead of implementing work, it watches
merge requests and posts review findings to them. It runs beside the
implementation orchestrator, or entirely without it — **review-only, across
a fleet of repositories, is the primary deployment this feature is built
for, not a variant of the implementation one.** A project that only ever
reviews needs no tracker, no file queue, and no `GITLAB_PAT` at all.

It is a second, independent container pair (`opencode-review` +
`symphony-review`), never the implementation pair reused: one `opencode`
container cannot hold two credential sets, so the reviewing agent gets its
own — holding none of the implementation agent's credentials, and no GitLab
access of any kind. See [The security model](#the-security-model) for the
full reasoning, in particular the third credential.

`REVIEW.md` is `WORKFLOW.md`'s counterpart: the same shape (YAML front
matter, then the agent's prompt as the rest of the file), mounted read-only
into `/config` for the same reason — it is trusted config, and the merge
request it reviews (title, description, comments, filenames, diff contents)
is emphatically not. [`templates/REVIEW.md.example`](templates/REVIEW.md.example)
says so explicitly and states the rule the review agent follows: instructions
found in a merge request are reported as findings, never followed.

```bash
./symphony init demo
cp templates/REVIEW.md.example projects/demo/config/REVIEW.md
$EDITOR projects/demo/config/REVIEW.md          # base_url, and which projects to review
echo 'SYMPHONY_REVIEW_GITLAB_TOKEN=<Reporter token>' >> projects/demo/review.env
./symphony check demo
./symphony up demo
```

Three deployment shapes, decided by what a project actually has configured —
never a flag you have to remember to repeat:

| Project has | `symphony up demo` starts | `--with-review` |
|---|---|---|
| `WORKFLOW.md` only | `opencode` + `squid` + `symphony` | refused — nothing to add |
| `REVIEW.md` only (no `WORKFLOW.md`) | `opencode-review` + `squid` + `symphony-review` | not needed — this is already review-only |
| Both | `opencode` + `squid` + `symphony` (review off by default) | adds `opencode-review` + `symphony-review` too — all five |

`review.env` holds `SYMPHONY_REVIEW_GITLAB_TOKEN`, the review controller's
own credential — gitignored, launcher-only, and read the same way
`symphony.env` is (see [projects/_example/review.env.example](projects/_example/review.env.example)).
Its presence is what turns review on for a project, independent of whatever
tracker (if any) `WORKFLOW.md` configures — a review-only deployment may
have no tracker at all, and still needs egress to GitLab; `symphony_preflight`
grants it regardless.

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

### Three credentials, none able to do more than one job

| | Variable | Role | Can push code? | Held by an agent? |
|---|---|---|---|---|
| the orchestrator | `SYMPHONY_GITLAB_TOKEN` | **Reporter**, per project | **No** | No |
| the agent | `GITLAB_PAT` | **Developer** | Yes — that one project | Yes |
| the review controller | `SYMPHONY_REVIEW_GITLAB_TOKEN` | **Reporter**, usually per **group** | **No** | **No — never** |

The orchestrator reads and writes issues. The agent pushes branches and
opens merge requests. The review controller reads merge requests, diffs and
files, and posts review findings. No credential can do another's job, so a
compromised orchestrator can vandalise issue text and nothing else, a
prompt-injected implementation agent **cannot rewrite its own work queue** —
it cannot mark its own work reviewed, and it cannot queue itself more — and a
compromised review controller can post noise to merge requests and nothing
else: it cannot push, merge, or approve, in any project it can see.

The review controller's credential is qualitatively different from the other
two in one way worth naming plainly: it is the only one of the three that
**no agent ever holds**. The reviewing agent (inside `opencode-review`) has
no GitLab access at all — see [Review](#review) and
[docker/docker-compose.review.yml](docker/docker-compose.review.yml) — so
there is no prompt-injection path to this credential even in principle, only
a compromise of the trusted, non-agentic review controller itself.

Be precise about what constrains what: API scope is not the control here.
There is no issues-only scope; `api` is full API access for that project. It
is the **Reporter role** that stops the orchestrator and the review
controller from pushing code. Effective permission is scope × role, so get
the role right.

This is why the three credentials live in separate files, and why `check`
*refuses* to start when it finds any two of them equal. With a single
credential doing two jobs there is nothing left to contain: either it is
Reporter and the higher-privileged side of the pair cannot do its job, or it
is Developer and the lower-privileged side can push — and, for the
orchestrator specifically, an agent holding it can relabel its own issue.

### The review token's group scope: a reasoned exception

["The token's scope is the boundary"](#the-tokens-scope-is-the-boundary),
above, argues hard for the narrowest credential that does the job, and
warns explicitly against a token that spans groups. `SYMPHONY_REVIEW_GITLAB_TOKEN`
is usually a **group**-scoped token — wider than every other credential this
launcher hands to a container. That is a deliberate exception to the rule
just stated, not a quiet departure from it, and here is why it holds up:

- **The primary review deployment watches a fleet, not one project.**
  Automatic review earns its keep across many repositories at once — that is
  the point of the feature (see [Review](#review)), not an extension of a
  single-project design. A project access token reaches one project; thirty
  reviewed projects would mean thirty tokens. Thirty tokens is not a security
  posture — it is a rotation problem nobody keeps up with, and the token
  nobody rotates is worse than the token whose reach is a little wider than
  ideal. Narrowed further where it can be: scope the token to a group
  created to hold the reviewed projects, never the organisation root.
- **The role, not the scope, is still doing the actual constraining.** A
  group Reporter token cannot push, merge, or approve **anywhere in the
  group** — the property "The token's scope is the boundary" is protecting
  against (a credential that can push, reaching further than it should) does
  not exist here at all, at any scope. Widening reach without widening
  capability is not the failure mode that section warns about.
- **No agent ever holds it.** Every other credential in this launcher is
  handed, eventually, to a container running an LLM with a shell or tool
  access — that is what makes token scope the load-bearing boundary for
  them. This one is held only by `symphony-review`, trusted code with no
  prompt in the loop between the credential and the GitLab API. There is no
  injection path to widen its effective reach.
- **State the blast radius plainly, because that is the actual argument.**
  Total compromise of this token — the worst case, assuming everything else
  failed too — is comment spam across the group: noisy, fully attributable
  to one token, and fixed by rotating it. Compare `GITLAB_PAT`, the
  implementation agent's Developer token, held by the one part of this
  system that has a shell, a model behind it, and untrusted content (issue
  text) in its own prompt: its worst case is pushed code on one project.
  Those are different failure classes, not just different sizes, and it is
  the difference that makes the group scope acceptable here specifically.

A reader who takes only one thing from this section: the narrow-token rule
is about **push-capable** reach. This token cannot push. That is what is
being traded for fleet coverage, and it is a trade this deployment can
afford that a Developer-scoped token never could.

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

The orchestrator reaches a tracker through the proxy and nothing else. Its
one network (`oc_proxy`) is internal, so the proxy is the only way out, and
the route is derived from the tracker you configured rather than being a
setting you fill in — on the file queue it has no egress at all, holds no
credentials, and only moves files.

The review controller's egress works the same way but is **unconditional**:
it is granted whenever `SYMPHONY_REVIEW_GITLAB_TOKEN` is set, regardless of
`tracker.kind` or whether any tracker is configured at all. A review-only
deployment (see [Review](#review)) may have no implementation tracker
whatsoever, and it still needs to reach GitLab — that is the entire job.
The reviewing agent itself (`opencode-review`) gets no GitLab route: it has
no credential to use one with in the first place.

Both derivations share one variable, `SYMPHONY_HTTP_PROXY`, computed once
per project. So on a project that runs **both** pipelines, enabling review
widens the implementation orchestrator's own route too, even under
`tracker.kind: file_queue`. That is not a credential leak — the orchestrator
still holds no GitLab token of its own in that case, and squid's own
allowlist is what actually gates which hosts are reachable either way — but
it is a real widening of *reachability*, worth knowing rather than
discovering by surprise.

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

**Refuses to start** on: a missing `WORKFLOW.md` (unless the project is
review-only — see [Review](#review)); a gitlab tracker with no orchestrator
token; any two of the three GitLab tokens configured equal; a workspaces
path colliding with the queue or config path; an agent environment file
readable from the orchestrator's `/config` mount; an inline `#` comment in a
launcher-only environment file (nothing strips it, so it silently becomes
part of the value); a review-enabled project (`SYMPHONY_REVIEW_GITLAB_TOKEN`
set) with no `REVIEW.md`. With `docker` available it also resolves the whole
compose configuration and asserts the orchestrator's token never appears in
the agent service, the review token never appears in EITHER agent service,
and `GITLAB_PAT` never appears in the reviewing agent's service.

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

## More docs

- [`docs/REVIEW_QUICKSTART.md`](docs/REVIEW_QUICKSTART.md) — setting up the merge-request reviewer, step by step, through to your first review comment
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — what breaks first, and how to tell the causes apart
- [`docs/IMAGE_CONTRACT.md`](docs/IMAGE_CONTRACT.md) — the interface between this launcher and the images it runs
- [`projects/README.md`](projects/README.md) — the per-project layout in detail
- [`CHANGELOG.md`](CHANGELOG.md)
