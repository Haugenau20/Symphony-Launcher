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
   moved, and posts **inline comments on individual diff lines for findings
   it can place with certainty, plus a summary comment** every time.

The agent never touches GitLab. A separate trusted component holds the
credential and does the posting. That split is the whole design: if the agent
were completely compromised by something written in a merge request, the worst
it could do is produce a bad review.

## What it does not do (yet)

- **Inline comments are best-effort, not guaranteed.** A finding is only
  placed on its diff line when the position can be validated against the
  diff with certainty; anything that cannot be confirmed stays in the
  summary comment instead of being guessed at. The summary comment is always
  posted, with or without inline findings — see `review.inline_comments`
  below.
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

### `review.inline_comments`

```yaml
review:
  inline_comments: true   # the shipped default
```

When `true`, a finding tied to a specific line is posted as a comment on
that line in the merge request's Changes view, instead of only appearing in
the summary comment. A finding whose line cannot be confirmed against the
diff always falls back to the summary comment rather than being guessed at,
and the summary comment is posted on every review regardless — even one
with no findings at all.

Re-reviewing a new commit replies to the previous revision's inline threads
and attempts to resolve them. Resolution is not guaranteed: a Reporter-role
token (see Step 1) may not have permission to resolve a thread, in which
case the reply is still posted but the thread stays open.

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

Then open the merge request. With `inline_comments: true` (the default), most
findings appear as comments on their own lines in the **Changes** tab, and the
summary comment holds whatever could not be placed there — so a short summary
comment usually means placement worked, not that little was found. It says how
many went inline.

Set `inline_comments: false` and everything arrives in that one comment
instead: a summary line, then findings grouped under **Blocking** /
**Concern** / **Nit**, each naming a file and line.

Either way the summary comment is posted, every time. If the reviewer found
nothing it still posts and says so — silence always means the reviewer did not
run, never that it approved.

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

## Debugging a review that failed

The confusing failure is `agent did not write FINDINGS.json`: the log shows the
session created, the agent reporting completion, and then nothing. Work through
these in order.

**1. Is your REVIEW.md the current one?** This is the most common cause by far.
An early version of the shipped template asked for findings as markdown in the
reply rather than as a file, so an agent following it does exactly this —
finishes confidently, writes nothing.

```bash
grep -c FINDINGS.json projects/<name>/config/REVIEW.md
```

`0` means your `REVIEW.md` predates the current template and never asks for the
file. Re-copy it and re-apply your edits:

```bash
cp templates/REVIEW.md.example projects/<name>/config/REVIEW.md
```

**2. Read the `review_worker_findings_missing` log line.** It lists what the
workspace actually held when the run ended:

```json
{"workspaceEntries":["MR.md (1841 bytes)","diff/ (3 entries)","files/ (3 entries)","review-notes.md (412 bytes)"],
 "msg":"review_worker_findings_missing"}
```

That tells you which failure you have:

| What you see | What it means |
|---|---|
| `MR.md`, `diff/`, `files/` and nothing else | The agent read its material and wrote nothing. A prompt problem — see step 1. |
| An extra file like `review-notes.md` or `findings.md` | The agent wrote its findings somewhere else. The prompt is not being followed; make step 4 of it more prominent. |
| `diff/ (0 entries)` | The agent had nothing to review. Check `exclude_paths` is not matching everything. |
| Only `MR.md` | Material fetching failed earlier — look for a warning above this line. |

**3. Keep the sandbox and look inside it.** The workspace is normally deleted as
soon as the job ends. To preserve failed ones:

```bash
# in projects/<name>/config/REVIEW.md
review:
  keep_failed_workspaces: true
```

or, without editing config, for one restart:

```bash
SYMPHONY_REVIEW_KEEP_FAILED_WORKSPACES=1 ./symphony up <name>
```

Then, after a failure:

```bash
ls -la projects/<name>/review-workspaces/*/
cat projects/<name>/review-workspaces/*/MR.md
```

You are looking at exactly what the agent saw. Turn it back off afterwards —
they accumulate, and they contain the merge request's content.

**4. Watch the agent work.** `./symphony logs <name>` follows the review
controller. For the agent's own side of the conversation, look at the
`opencode-review` container instead:

```bash
docker ps --format '{{.Names}}' | grep opencode-review     # find the exact name
docker logs -f symphony-<project-slug>-opencode-review
```

That is where a permission denial or a tool error would appear — the controller
only sees that the run ended.

## Troubleshooting

| What you see | What it means |
|---|---|
| No `review_dispatched` at all | Nothing matched. Check the MR is open, non-draft, not from a fork, and that `projects:` names the full path (`group/repo`). |
| `review_skipped_too_large` | The diff exceeded `max_diff_bytes`, or GitLab collapsed every file. Raise the cap or add `exclude_paths`. It refuses rather than reviewing part of a change and presenting it as complete. |
| `review_job_failed` with `did not write FINDINGS.json`, and `agentSaid` mentions **permission denied** | The agent could read its material but not write. The workspace is a bind mount shared with the agent container: if the review controller created it as root, the agent — running as `HOST_UID` — can read it and cannot write to it. Rebuild the orchestrator image; its entrypoint chowns the mounted volumes to `HOST_UID` and runs as that user. Check with `ls -ln projects/<name>/review-workspaces/` — the directories must be owned by your `HOST_UID`, not by `0`. |
| `review_job_failed` with `did not write FINDINGS.json`, no permission error | The agent never produced its output file. Usually an edited prompt that dropped the `FINDINGS.json` instructions — see the debugging section above. |
| `review_job_failed` with `findings rejected` | The agent wrote malformed JSON. Nothing is published — it fails rather than posting a partial review. It retries with backoff up to `max_attempts`. |
| `review_superseded_*` | Someone pushed a new commit mid-review. The stale review is discarded; the new head is picked up on a later poll. Working as intended. |
| Config validation error about `agent.permissions` | A line in your `REVIEW.md` disagrees with what the controller actually enforces (`edit: allow`, everything else `deny`). That block documents the sandbox and cannot change it — including in the safe-looking direction: `edit: deny` describes a reviewer that could not write `FINDINGS.json`, and so could not produce a review at all. Correct the line or delete it. |
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
