# extra-allowlist.d/

Squid's egress allowlist, in `.conf` drop-ins. `docker-compose.yml` mounts
this directory read-only into the squid container
(`/etc/squid/extra-allowlist.d`) as the checkout-wide default every project's
stack shares unless it ships its own.

This directory is the right default for a project that genuinely needs
several services (Bitbucket, Jira, JFrog, Confluence, M-Files) reachable
through squid. A symphony project usually does not — see below.

## A symphony project should ship its own

Drop `.conf` files into `projects/<name>/allowlist.d/` covering **only** the
LLM endpoint and GitLab: those are the only two hosts a symphony agent
(and, under `tracker.kind: gitlab`, the orchestrator) has any legitimate
reason to reach. That reduction happens *before* any credential comes into
play — an MCP server for a service that isn't even allowlisted here has one
less way to matter if it were ever misconfigured on, and squid's deny log is
shorter and more legible when it only ever denies things that are actually
suspicious.

## It's opt-in, not automatic

`./symphony` only points `EXTRA_ALLOWLIST_PATH` at a project's own
`allowlist.d/` when that directory **exists**. If a project has not created
one, the stack falls back to this checkout-wide directory rather than
mounting an empty directory over it — an empty mount would silently allow
nothing at all, which is a much louder failure than "shares the default
list" and not the one you'd want by surprise.

## Format

One or more `.conf` files, loaded by squid in filename order — see the
files already here (if any) for the directive syntax, and squid's own
`http_access`/`acl` documentation for the rest. Keep entries scoped to a
single host per rule; a broad allow defeats the point of having a list at
all.
