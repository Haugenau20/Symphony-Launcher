# Running the merge-request reviewer

A step-by-step for setting up the review pipeline and getting your first
review comment onto a real merge request.

Read [the README's "The security model"](../README.md#the-security-model)
before the first real run. This guide tells you *what to type*; that section
tells you *why the token is shaped the way it is*, which is the part worth
understanding before you point this at anything you care about.

---

## What it does

Every poll (default: 60s) it asks GitLab for open merge requests in the
projects you listed. For each one it has not already reviewed at that exact
commit, it:

1. fetches the diff and the changed files' contents **with trusted code**,
2. writes them into a throwaway directory,
3. runs a reviewing agent that has **no GitLab token, no network access, and
   no ability to edit, run shell commands, or leave that directory**,
4. validates what the agent produced, re-checks that the commit has not
   moved, and posts **one summary comment** on the merge request.

The agent never touches GitLab. A separate trusted component holds the
credential and does the posting. That split is the whole design: if the agent
were completely compromised by something written in a merge request, the worst
it could do is produce a bad review.

## What it does not do (yet)

- **No inline comments on diff lines.** One summary comment per revision.
- **No fork merge requests.** They are detected and skipped with a recorded
  reason. Supporting them means widening the token, which breaks the model.
- **No webhooks.** It polls. That means it works behind NAT and recovers on
  its own after downtime.
- **Drafts are skipped** unless you set `include_drafts: true`.
- **It never approves, merges, or pushes anything.** It cannot.

---

## Before you start

- The launcher installed and working (`./symphony --help` runs).
- Docker with the compose plugin.
- A GitLab group or project with at least one **open merge request** you don't
  mind getting a comment on. Use a scratch repo for the first run.
- Your `.env` filled in with `IMAGE_REGISTRY` / `IMAGE_TAG` as for any other
  project.

---

## Step 1 — Create the review token

In GitLab: **Group** (or Project) → **Settings** → **Access tokens** → *Add new
token*.

| Field | Value | Why |
|---|---|---|
| Role | **Reporter** | Reporter cannot push code, cannot merge, cannot change settings. This is the actual boundary — not the scope. |
| Scope | `api` | Posting a comment is a write, so `read_api` is not enough. Combined with Reporter, `api` still cannot push. |
| Expiry | Set one | Rotate it like any other credential. |

Scope it as narrowly as the rollout allows. A **group** token covering a group
that contains exactly the repos you want reviewed is the intended shape — one
token to rotate instead of thirty. The README argues hard for narrow tokens,
and this is a deliberate, reasoned exception: the holder is Reporter (it cannot
push anywhere), and no agent ever holds it. The worst case on total compromise
is comment spam, not pushed code.

**This token must be different from your other two.** The launcher refuses to
start if any two of `GITLAB_PAT`, `SYMPHONY_GITLAB_TOKEN` and
`SYMPHONY_REVIEW_GITLAB_TOKEN` are equal.

## Step 2 — Scaffold the project

```bash
./symphony init my-review
```

This creates `projects/my-review/` with its config, workspace and env files.
For a **review-only** project you will not need `WORKFLOW.md` at all — that
file drives the *implementation* pipeline, which you are not starting here.

## Step 3 — Write REVIEW.md

```bash
cp templates/REVIEW.md.example projects/my-review/config/REVIEW.md
$EDITOR projects/my-review/config/REVIEW.md
```

The front matter is the configuration; everything below it is the prompt the
reviewing agent receives, **verbatim**. Set at minimum:

```yaml
review:
  base_url: https://gitlab.your-company.example

  # Start with ONE repository. Judge the output before adding more.
  projects:
    - my-group/my-test-repo

  poll_interval_ms: 60000
  include_drafts: false
  exclude_paths:
    - "**/*.lock"
    - "**/dist/**"
  max_diff_bytes: 400000
```

Once you trust it, swap `projects:` for `group_id: my-group` — one API call per
poll no matter how many repositories the group holds.

> **Editing the prompt:** the body is passed to the agent exactly as written.
> It is *not* templated — `{{ mr.title }}` and friends would appear literally,
> and putting the merge-request title into the instructions is precisely what
> the untrusted/trusted split exists to prevent. The agent learns which MR it
> is reviewing from `MR.md` in its workspace.
>
> If you rewrite the prompt, **keep the `FINDINGS.json` section**. That file is
> the agent's only output; a prompt that forgets to ask for it produces a
> failed review every time.

## Step 4 — Put the token in review.env

```bash
cp projects/_example/review.env.example projects/my-review/review.env
$EDITOR projects/my-review/review.env
```

```bash
SYMPHONY_REVIEW_GITLAB_TOKEN=glpat-xxxxxxxxxxxxxxxxxxxx
```

This file is launcher-only and gitignored. The token reaches the review
controller through that service's own `environment:` block and **never**
through `env_file:` — which is what keeps it out of both agent containers.
Do not put it in `.env` or `projects/my-review/.env`.

## Step 5 — Preflight

```bash
./symphony check my-review
```

This changes nothing on disk. It refuses to start on a missing `REVIEW.md`, a
missing token, or any two of the three tokens being equal. With docker
available it also resolves the full compose config and proves:

- the review token appears in **neither** agent container, and
- `GITLAB_PAT` never appears in `opencode-review`.

Those two assertions are what make "the reviewer cannot push" mechanical
rather than a promise. Do not skip this step; it is the cheapest part of the
whole setup.

---

## Step 6 — The first run

Make sure your test repo has **one open, non-draft merge request** that is not
from a fork.

```bash
./symphony up my-review
./symphony logs my-review
```

A review-only project starts `opencode-review`, `squid` and `symphony-review`
— it does **not** start the implementation stack.

In the logs you are looking for this sequence:

```
review_mode_starting
review_config_loaded      {"projectCount":1,"pollIntervalMs":60000}
review_dispatched         {"project":"my-group/my-test-repo","mrIid":42,...}
review_published          {"noteId":"..."}
```

Then open the merge request. You should see one comment: a summary line, then
findings grouped under **Blocking** / **Concern** / **Nit**, each naming a file
and line. If the reviewer found nothing, it still posts and says so — silence
always means the reviewer did not run, never that it approved.

### Watching the state directly

The store is a directory tree, so `ls` is the dashboard:

```bash
ls projects/my-review/review-store/projects/*/     # per-MR records
ls projects/my-review/review-store/claimed/        # in flight right now
ls projects/my-review/review-store/failed/         # failed, awaiting retry
```

Each record is JSON with its state, attempt count and the published note id.

### Stopping

```bash
./symphony down my-review
```

In-flight reviews are left claimed and re-run on the next start. Nothing was
published for them, so a re-run costs only time.

---

## Step 7 — Verify the safety properties yourself

Worth doing once, so you trust it rather than taking this document's word:

```bash
# The review token must appear ONLY in the review controller.
./symphony config my-review | grep -c SYMPHONY_REVIEW_GITLAB_TOKEN

# The push credential must be absent from the reviewer's agent container.
./symphony config my-review | awk '/^  opencode-review:/,/^  [a-z]/' | grep GITLAB_PAT
```

The second command should print nothing. If it prints anything, stop and
report it — that is the invariant the whole deployment rests on.

---

## Troubleshooting

| What you see | What it means |
|---|---|
| No `review_dispatched` at all | Nothing matched. Check the MR is open, non-draft, not from a fork, and that `projects:` names the full path (`group/repo`). |
| `review_skipped_too_large` | The diff exceeded `max_diff_bytes`, or GitLab collapsed every file. Raise the cap or add `exclude_paths`. It refuses rather than reviewing part of a change and presenting it as complete. |
| `review_job_failed` with `did not write FINDINGS.json` | The agent never produced its output file. Almost always an edited prompt that dropped the `FINDINGS.json` instructions. |
| `review_job_failed` with `findings rejected` | The agent wrote malformed JSON. Nothing is published — it fails rather than posting a partial review. It retries with backoff up to `max_attempts`. |
| `review_superseded_*` | Someone pushed a new commit mid-review. The stale review is discarded; the new head is picked up on a later poll. Working as intended. |
| Config validation error about `agent.permissions` | Your `REVIEW.md` tried to grant the agent `edit`/`bash`/`webfetch`/`external_directory`. That block documents the sandbox and cannot widen it. Set it to `deny` or delete the line. |
| Nothing in `./symphony logs` | The controller container is not running. `./symphony status my-review`. |

---

## Rolling it out

1. **One repository, one week.** Read every comment it posts and ask whether
   you would have wanted it. Reviewer noise is the only failure mode that
   actually costs anything here — a review nobody trusts is worse than none.
2. **Tune `exclude_paths` first.** Most early noise is generated files,
   lockfiles and vendored code.
3. **Then add repositories one at a time**, still with an explicit `projects:`
   list, so each addition is a deliberate act.
4. **Then switch to `group_id:`** once it has earned blanket coverage.

If you want to run the reviewer alongside the implementation pipeline on the
same project, configure both and start with `./symphony up my-project
--with-review`.
