# projects/

Everything that differs between the stacks this launcher runs lives under
here, one directory per project:

```
projects/<name>/
├── .env             # agent-visible,   per-project   (this project's scoped credentials)
├── symphony.env     # launcher-only,   per-project    (this project's Reporter token, if any)
├── config/
│   └── WORKFLOW.md  # tracker choice, run limits, the agent's prompt — trusted, read-only
├── queue/           # file_queue tracker only: todo/ in-progress/ review/ done/ failed/ cancelled/
├── workspaces/       # per-item agent clones — always created, whichever tracker
└── allowlist.d/      # optional: this project's own squid egress allowlist
```

## Four config layers, last wins

Two splits, at right angles to each other.

**Agent vs orchestrator.** `.env` files are handed to the agent's container
wholesale via `docker-compose.yml`'s `env_file:` directive. `symphony.env`
files are read only by `./symphony` and passed to `docker compose` via
`--env-file`, which drives `${VAR}` interpolation and puts nothing directly
inside a container — that is the mechanism that keeps the orchestrator's
Reporter token out of the agent's environment, not a filing convention.

**Shared vs per-project.** Read in this order, last value wins:

| | agent-visible | launcher-only |
|---|---|---|
| shared | `.env` | `symphony.env` |
| per-project | `projects/<name>/.env` | `projects/<name>/symphony.env` |

A per-project value can also *blank* an inherited one (`CONFLUENCE_PAT=`).
Every MCP server in the image auto-enables on credential **presence**, so a
blank keeps that server out of one project's stack while another project
keeps its own — absent, not disabled. A key merely left *out* of a
per-project file is inherited from the shared one instead, which is why
`_example/.env.example` writes its blanks explicitly rather than omitting
the keys.

## Why `config/` is a subdirectory, not a peer of `symphony.env`

`docker-compose.symphony.yml` bind-mounts `projects/<name>/config/` — and
only that directory — read-only into the orchestrator container, as
`/config/WORKFLOW.md`. Putting `WORKFLOW.md` one level down from
`symphony.env` is load-bearing, not tidy: it is what keeps this project's
credential files (`.env`, `symphony.env`) from ever being reachable from
inside a container that is supposed to hold the Reporter token and nothing
else. `symphony check` refuses to start if an agent env file is readable
from in there.

## Creating a project

```
./symphony init <name>
```

Scaffolds `projects/<name>/` from `_example/`, including empty `queue/` and
`workspaces/` directories. Then:

1. Copy a workflow template into `config/WORKFLOW.md` and edit it — see
   `templates/WORKFLOW.md.example` (file queue) or
   `templates/WORKFLOW.gitlab.md.example` (GitLab issues).
2. Copy `.env.example` and `symphony.env.example` to `.env` and
   `symphony.env` in the project directory and fill them in.
3. Optionally add `allowlist.d/*.conf` to trim this project's squid egress —
   see `extra-allowlist.d/README.md`.
4. `./symphony check <name>` before the first `up`.

## What's tracked here

Everything under `projects/` is gitignored except this file and `_example/`,
which ships as a template rather than a real project — `./symphony init`
reads from it but nothing runs against it directly.
