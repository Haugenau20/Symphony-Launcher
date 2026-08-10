#!/usr/bin/env bash
#
# Run the symphony test suite. Uses a system `bats` if present; otherwise
# fetches bats-core into tests/.bats (gitignored) on first run.
#
#   ./tests/run.sh              # run everything
#   ./tests/run.sh cli.bats     # one file
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
BATS_DIR="$HERE/.bats"

if [ "$#" -gt 0 ]; then
  # Resolve bare names (e.g. "cli.bats") against the tests dir so the suite can
  # be targeted from any working directory; leave explicit paths untouched.
  TARGETS=()
  for t in "$@"; do
    case "$t" in
      */*|/*) TARGETS+=("$t") ;;
      *)      TARGETS+=("$HERE/$t") ;;
    esac
  done
else
  TARGETS=("$HERE"/*.bats)
fi

pick_bats() {
  if [ -x "$BATS_DIR/bin/bats" ]; then
    printf '%s' "$BATS_DIR/bin/bats"; return 0
  fi
  if command -v bats >/dev/null 2>&1; then
    command -v bats; return 0
  fi
  return 1
}

if ! BATS="$(pick_bats)"; then
  echo "==> bats not found; fetching bats-core into tests/.bats ..." >&2
  if ! git clone --depth 1 https://github.com/bats-core/bats-core.git "$BATS_DIR" >/dev/null 2>&1; then
    echo "error: could not fetch bats-core (no network?)." >&2
    echo "       install bats — https://bats-core.readthedocs.io — and re-run." >&2
    exit 1
  fi
  BATS="$BATS_DIR/bin/bats"
fi

exec "$BATS" "${TARGETS[@]}"
