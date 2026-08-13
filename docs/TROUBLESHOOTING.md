# Troubleshooting

Failures ordered by how likely you are to hit them on a fresh deployment.
None of the integrations here have run against real infrastructure yet (see
the README's "What is not verified"), so expect the first real run to find
something on this list.

For every entry: what to look at, and whether `symphony check <name>` or
`symphony config <name>` would have caught it beforehand.

## `TypeError: fetch failed` on the first poll, before any issue is picked up

The single most likely failure on a fresh `gitlab` tracker. Symphony cannot
reach GitLab, and the error message alone does not say why — there are
three independent things that can cause exactly this text, and telling them
apart from inside the container is the fix:

```sh
docker exec symphony-<name>-orchestrator \
  curl -sS -o /dev/null -w '%{http_code}\n' https://<your-gitlab>/api/v4/version
docker exec symphony-<name>-orchestrator \
  node -e 'fetch("https://<your-gitlab>/api/v4/version").then(r=>console.log(r.status)).catch(e=>console.log(e.cause?.code??e.message))'
```

- **`curl` works, `node` fails** — the **proxy** problem. `curl` honours
  `HTTP_PROXY`/`HTTPS_PROXY`; Node's global `fetch` is undici, and undici
  **ignores** those variables — something has to build a `ProxyAgent` from
  them explicitly. If the `-symphony` image you are running predates that
  fix in its GitLab tracker code, this is the exact bug — pull a newer tag.
- **Both fail with a TLS error** — the **CA** problem. `update-ca-certificates`
  populates the system trust store; Node ships its own bundle and does not
  read the system one, so it needs `NODE_EXTRA_CA_CERTS` pointed at your
  corporate CA explicitly. That is baked into the `-symphony` image itself,
  not something this launcher's compose files or env layers configure.
- **Both fail to connect at all** — squid's **egress allowlist**. Add the
  GitLab host under `extra-allowlist.d/` (checkout-wide) or
  `projects/<name>/allowlist.d/` (this project only, and the one you want
  for a symphony deployment — see
  [`extra-allowlist.d/README.md`](../extra-allowlist.d/README.md)).

`symphony check <name>` warns before you ever hit this: it checks whether
the tracker's `base_url` host is mentioned by any `*.conf` in the resolved
allowlist directory, and its warning names this exact failure by message.
It cannot check the proxy-vs-CA split, since both of those only surface at
runtime inside the container.

## The clone fails

The agent's own first bash command, not anything symphony's container does
— the orchestrator deliberately holds no repository credential and never
clones on your behalf (see the README's security section). Two likely
causes:

- **Wrong URL in `WORKFLOW.md`'s "First: clone the project" section.** It
  has to be edited by hand to match `tracker.project_id`; nothing
  auto-fills it. `symphony check <name>` warns if the prompt body never
  mentions `tracker.project_id` at all, which catches "you forgot to edit
  it" but not "you edited it to the wrong project."
- **The destination isn't covered by `GIT_REMOTE_ALLOWLIST`.** `check`
  cross-checks the tracker's own project against the allowlist and warns if
  it isn't covered — "the workflow tells the agent to clone it and
  git-guard will refuse." If `check` passed and the clone still fails,
  read the agent's own transcript for the exact git error.
- **The agent has no credential.** `check` refuses a gitlab tracker whose
  `projects/<name>/.env` has no `GITLAB_PAT`, because the clone is the agent's
  first step and it cannot take one without a token. If you added the token and
  it still behaves as though it is missing, read the next section.

## A credential you added doesn't seem to reach the agent

**Environment variables are fixed when a container is CREATED, not when it
starts.** Editing `projects/<name>/.env` and then restarting changes nothing the
agent can see — `./symphony stop` and a restart, or `docker restart`, both reuse
the existing container with the environment it was built with.

```bash
./symphony down <name> && ./symphony up <name>
```

`up` recreates services whose resolved configuration changed, which is what
actually re-reads the file. This is the likeliest explanation for a value that
"only works in the root `.env`": editing the root file changes compose's
interpolation inputs, which can force a recreate that the per-project edit alone
did not — so both files get re-read at once and the wrong one takes the credit.

To see what the agent will get, before starting anything:

```bash
./symphony config <name> | awk '/^  opencode:/,/^  [a-z]/' | grep GITLAB_PAT
```

And what a RUNNING container actually got, which is the value that matters:

```bash
docker exec symphony-<slug>-opencode printenv GITLAB_PAT
```

If the first shows your token and the second does not, the container is stale —
recreate it. Both layers do reach the agent: `.env` for what every project
shares and `projects/<name>/.env` for what differs, last one winning. The
per-project file is the right home for a scoped credential; the shared root file
would hand the same token to every project on the host.

## The run is killed after a few minutes

`stall_timeout_ms` is too low for work that clones a repository. Look for a
`stall_detected` line in `symphony logs <name>`. This setting is currently a
**run timeout**, not an actual stall detector — it stamps the moment a run
starts and nothing updates that stamp while the agent works, so a run dies
once it has simply been *alive* long enough, regardless of progress.
300000ms (5 minutes, the image's built-in default) is fine for a stage-0
hello-world item on the file queue and far too short for anything that
clones a repository — raise it to at least 1800000 (30 minutes) before a
real GitLab run.

`symphony check <name>` warns when a `gitlab`-tracker workflow sets
`stall_timeout_ms` under 600000ms, by name, pointing at this exact
misunderstanding.

## 403s, and which token is which

Symphony's own Reporter token (`SYMPHONY_GITLAB_TOKEN`) **cannot** open
merge requests, comment with write access beyond issues, or push code — and
a 403 from it on any of those is **correct behavior**, not a bug to route
around. The agent's Developer token (`GITLAB_PAT`) is the one that pushes
branches and opens MRs; a 403 on *merge* from that token is also expected —
merging is a human decision, and neither token can do it.

If a 403 doesn't fit that shape — the agent's token failing to push, or
symphony's token failing to read/write issues — check which token actually
landed where: `symphony config <name>` prints the fully resolved
`docker compose config`, and `symphony check <name>` cross-checks that
`SYMPHONY_GITLAB_TOKEN`'s value never appears in the `opencode` service's
resolved block (if it does, something has gone seriously wrong with the
env-file layering) and warns if the two tokens are identical (defeating
the entire role split).

## Nothing is picked up at all

Label names must match `label_prefix` **exactly**, including the `::`
separator — `symphony::todo`, not `symphony:todo` or `Symphony::Todo`. An
issue carrying none of the six `<label_prefix>::<state>` labels is not
symphony's and is silently ignored; that is intentional (it is how an
ordinary backlog coexists in the same project), which also means a typo
here produces no error anywhere — just an issue that never gets worked.
Confirm the six labels exist on the project first:
`<label_prefix>::todo`, `::in-progress`, `::review`, `::done`, `::failed`,
`::cancelled`. `symphony status <name>` prints the derived board URL for a
quick visual check. `check` does not (and cannot) verify labels exist on
the remote — it has no read access to GitLab itself, only to `WORKFLOW.md`.

## An item lands in `review` with no merge request

Expected, not a bug — see the README's "`review` means the agent stopped,
not that it finished." Look at the orchestrator's log for the
`agent_run_completed` line and its `stopReason`:

- `stopReason: max_turns` means the run was **interrupted** mid-task, not
  finished. Also logged separately as `agent_run_hit_max_turns` at warn
  level.
- On an older `-symphony` image there is no `stopReason` field at all — the
  tell instead is `turnsCompleted` landing **exactly** on `max_turns`,
  which is much more likely to be exhaustion than coincidence.

From there, the evidence for what actually happened is in three places:
the workspace on the host (`git log`, `git status -sb`, and
`git ls-remote --heads origin 'symphony/*'` — which separates "never
cloned" from "committed but never pushed" from "pushed but no MR"), the
issue's workpad comment (if `ALLOW_GITLAB_WRITE=1`), and the OpenCode
session named by `sessionId` in the log. `symphony check <name>` warns
ahead of time if `completion_marker` is set but never mentioned in the
prompt body — the single most common root cause of hitting `max_turns`
on nearly every run.

## The `-symphony` image doesn't exist in your registry yet

Expected, not a bug in this launcher — this launcher is pull-only (see
[`docs/IMAGE_CONTRACT.md`](IMAGE_CONTRACT.md)) and publishing the
`-symphony` tag to your registry is a separate step from anything this
repository does. If that has not happened yet for your registry,
`symphony up <name>` fails at its single `docker compose pull opencode
squid symphony` step with an ordinary "manifest unknown" or similar
registry error naming the `-symphony` tag — `opencode` and `squid` are
ordinary, long-published images and are not expected to be the ones
missing. There is nothing to fix here except waiting for (or requesting)
that publish; do **not** add a `build:` block to work around it.
