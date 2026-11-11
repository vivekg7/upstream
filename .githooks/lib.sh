# Shared by every hook. Sourced, never executed.
#
# Hooks refuse; they never rewrite. `make fmt` is the one thing that edits, so
# nothing lands in a commit that nobody read. Every failure names its own fix
# and states the bypass plainly: a hook you cannot get past in an emergency is
# a hook that gets uninstalled.
#
# Written for bash 3.2 (what macOS ships): no mapfile, no associative arrays.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

die() {
  printf '\n\033[0;31m✗ %s\033[0m\n' "$1" >&2
  shift
  for line in "$@"; do printf '  %s\n' "$line" >&2; done
  printf '\n  Fix it, or bypass with --no-verify and own the consequences.\n\n' >&2
  exit 1
}

# Staged paths matching an extended regex, newline-separated.
staged() {
  git diff --cached --name-only --diff-filter=ACMR | grep -E "$1" || true
}

# Feed a newline-separated file list to a command, NUL-safely.
run_on() {
  local files="$1"
  shift
  printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 "$@"
}
