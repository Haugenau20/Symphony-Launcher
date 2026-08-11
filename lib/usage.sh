# shellcheck shell=bash
#
# lib/usage.sh — the --help / usage text.
#
# Sourced by the `symphony` entry point (not run standalone); see the
# source-order contract there. Pure function definition, no top-level side
# effects, so this file is safe to source for unit tests.

# --- usage / --help ---------------------------------------------------------
usage() {
  cat <<'EOF'
Usage:
  symphony init <name>
  symphony check <name>
  symphony up <name> [--publish] [--with-review]
  symphony logs <name>
  symphony status <name>
  symphony stop <name>
  symphony down <name>
  symphony add <name> "what the agent should do" [--id ID] [--title TITLE]
  symphony config <name>
  symphony projects
  symphony version
  symphony help | --help

Symphony is the opt-in unattended orchestrator: an agent runs headless
against a queue of work items until each one is ready for a human. This CLI
is verb-first with a PROJECT NAME, never a host-repo path — every stack lives
under projects/<name>/, and one checkout runs any number of them. Read
README.md's "The security model" before the first real run, especially the
GitLab-token scoping, and "Configuration: four layers" for the env-layering
contract.

Verbs:
  init <name>
             Scaffold projects/<name>/{config,queue,workspaces} (the six
             file_queue state dirs only when the tracker is file_queue or
             unknown yet), copy projects/<name>/{.env,symphony.env} from the
             shipped examples if they don't exist, and print next steps.
             Idempotent — creates nothing it doesn't already need to.
  check <name>
             Preflight only — changes nothing on disk. Refuses on a missing
             WORKFLOW.md, a gitlab tracker with no SYMPHONY_GITLAB_TOKEN, a
             workspaces path that collides with the queue or config path, an
             agent env file readable from the config mount, or an inline '#'
             comment in a launcher-only env file; warns on the quieter
             mistakes (a SYMPHONY_* key leaked into an agent-visible file,
             the same token used for symphony and the agent, a token
             inherited from the shared file, the two allowlists
             disagreeing, a completion_marker that never appears in the
             prompt, a non-empty hooks.after_create, an opencode.server_url
             mismatch, a GitLab clone URL that doesn't mention
             tracker.project_id, a tracker host missing from the egress
             allowlist, a stall_timeout_ms under 10 minutes, a placeholder
             IMAGE_REGISTRY, and — for the file queue — its six state
             directories not sharing one filesystem; in review mode, a
             missing config/REVIEW.md, or any two of the three GitLab
             tokens being equal). With docker on PATH, also resolves the
             full compose config and asserts SYMPHONY_GITLAB_TOKEN and
             SYMPHONY_REVIEW_GITLAB_TOKEN never appear in either agent
             service's block, and that GITLAB_PAT never appears in
             opencode-review's.
  up <name> [--publish] [--with-review]
             Preflight (abort before any docker call on failure), scaffold
             any missing directories, pull, then start whichever services
             this project actually configured: opencode + squid + symphony
             for an implementation project; opencode-review + squid +
             symphony-review for a review-only project (SYMPHONY_REVIEW_GITLAB_TOKEN
             set, no WORKFLOW.md — see templates/REVIEW.md.example); all five
             for both, when --with-review is passed on a project that has
             both configured. Headless, no web UI, unless --publish is
             given, which also starts the publish service and binds a host
             port (opt-in; nothing binds a host port otherwise).
  logs <name>
             Follow the orchestrator's log (--tail=100 -f), or the review
             controller's if THAT is the one running. No-ops (not an error)
             instead of calling compose at all when neither container is
             running. Ctrl-C detaches without affecting the stack.
  status <name>
             Per-state queue counts under tracker: file_queue, or the
             tracker's project/board under tracker: gitlab (never file
             counts there — leftovers from an earlier file_queue run would
             read as pending work the orchestrator isn't looking at).
             Always reports whether the orchestrator container is running,
             plus the review controller's too when this project has review
             configured.
  stop <name>
             Stop the orchestrator only; opencode/squid keep running.
             In-flight items stay in in-progress/ and resume on restart.
  down <name>
             Tear down the whole stack: opencode + squid + symphony, plus
             the publish service if it was ever brought up, plus
             opencode-review + symphony-review if review is configured.
  add <name> "<what the agent should do>" [--id ID] [--title TITLE]
             Queue a new file_queue item in todo/. Refuses under tracker:
             gitlab — there, work items are GitLab issues, not files; label
             one <label_prefix>::todo instead.
  config <name>
             Print the fully resolved `docker compose config` for <name> —
             four env layers plus derived per-project paths is more than you
             can resolve by reading the files.
  projects
             List every project under projects/: name, tracker, published
             port (if any), and whether it's up.
  version    Print the launcher version (from the VERSION file, if present).
  help, --help
             Show this help.

Layout:
  projects/<name>/
  ├── .env             per-project, AGENT-visible    -> PROJECT_ENV_FILE
  ├── symphony.env      per-project, LAUNCHER-ONLY — never named by any
  │                      env_file: directive, which is what keeps
  │                      SYMPHONY_GITLAB_TOKEN out of the agent's container
  ├── config/
  │   └── WORKFLOW.md   -> SYMPHONY_CONFIG_PATH, mounted read-only into the
  │                        symphony container. A subdirectory on purpose —
  │                        one level below symphony.env — so that mount can
  │                        never expose the project's own credentials.
  ├── queue/            -> SYMPHONY_QUEUE_PATH (file_queue state; unused
  │                        under tracker: gitlab)
  ├── workspaces/       -> SYMPHONY_WORKSPACES_PATH (per-item agent
  │                        workspaces; used by both trackers)
  ├── allowlist.d/      -> EXTRA_ALLOWLIST_PATH, opt-in: only used when the
  │                        directory exists.
  ├── review.env        per-project, LAUNCHER-ONLY — the review controller's
  │                      OWN file, same containment as symphony.env: never
  │                      named by any env_file: directive, which is what
  │                      keeps SYMPHONY_REVIEW_GITLAB_TOKEN out of BOTH
  │                      agent containers. See
  │                      projects/_example/review.env.example.
  ├── config/REVIEW.md  -> the review controller's trusted config + prompt,
  │                        mounted read-only alongside (or instead of)
  │                        WORKFLOW.md. See templates/REVIEW.md.example.
  ├── review-store/     -> SYMPHONY_REVIEW_STORE_PATH (review job state)
  └── review-workspaces/ -> SYMPHONY_REVIEW_WORKSPACES_PATH (per-MR disposable
                             review checkouts)

Four env layers, read in this order, last value wins:
  .env                            shared,      agent-visible
  symphony.env                    shared,      launcher-only
    -> per-project paths are derived here
  projects/<name>/.env            per-project, agent-visible
  projects/<name>/symphony.env    per-project, launcher-only

A fifth, review-only layer, projects/<name>/review.env, is read after all
four — see "Three credentials" in README.md's security model.

SYMPHONY_GITLAB_TOKEN must never reach the agent's container, and
SYMPHONY_REVIEW_GITLAB_TOKEN must never reach EITHER agent container. Both
reach compose ONLY via --env-file (interpolation, not a container mechanism)
and land inside a container ONLY through their own service's `environment:`
block (symphony, symphony-review respectively). Never put either in .env or
projects/<name>/.env; `check` verifies this both statically and against the
resolved compose config.

Notes:
  * Egress for the gitlab tracker is DERIVED from tracker.kind in
    WORKFLOW.md, never a setting you fill in — an explicit
    SYMPHONY_HTTP_PROXY in either symphony.env still wins. Review egress is
    granted whenever SYMPHONY_REVIEW_GITLAB_TOKEN is set, regardless of
    tracker.kind or whether a tracker is configured at all.
  * Port publishing is entirely opt-in (`up --publish`) — no verb binds a
    host port otherwise. Review adds no host port of its own, ever.
  * A project name must match ^[A-Za-z0-9][A-Za-z0-9._-]*$ — it becomes a
    path component and a compose project name.
EOF
}
