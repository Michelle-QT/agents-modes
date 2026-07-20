#!/usr/bin/env bash
set -euo pipefail

# Runs the test files named as arguments. Each tier of testing has its own make target,
# and the target names the files; this script never decides what tier it is running.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
: "${TEST_TMP_ROOT:=$(mktemp -d "${TMPDIR:-/tmp}/agents-modes-live-tests.XXXXXX")}"
export TEST_TMP_ROOT
: "${AGENTS_MODES_OUTER_CODEX_SANDBOX:=${CODEX_SANDBOX:-}}"
: "${AGENTS_MODES_OUTER_CLAUDE_MODE:=${AGENTS_CLAUDE_MODE:-}}"
export AGENTS_MODES_OUTER_CODEX_SANDBOX AGENTS_MODES_OUTER_CLAUDE_MODE
unset AGENTS_CLAUDE_MODE AGENTS_CODEX_MODE CODEX_SANDBOX RUNBOX_CONTAINER
rm -f "$TEST_TMP_ROOT/skips.tsv"

cleanup() {
  if [ "${KEEP_TEST_TMP:-0}" = "1" ]; then
    printf '# keeping live test temp dir: %s\n' "$TEST_TMP_ROOT" >&2
  else
    rm -rf "$TEST_TMP_ROOT"
  fi
}
trap cleanup EXIT

[ "$#" -gt 0 ] || { printf 'usage: run-live.sh <test-file>...\n' >&2; exit 2; }

for test_script in "$@"; do
  printf '==> %s\n' "$test_script"
  bash "$ROOT/tests/$test_script"
done

if [ -s "$TEST_TMP_ROOT/skips.tsv" ]; then
  printf 'incomplete - %s skipped evidence:\n' "${AGENTS_MODES_TIER:-live tests}" >&2
  cut -f2- "$TEST_TMP_ROOT/skips.tsv" | sed 's/^/  - /' >&2
  [ "${AGENTS_MODES_ALLOW_SKIP:-0}" = "1" ] \
    || { printf 'set AGENTS_MODES_ALLOW_SKIP=1 only when an incomplete run is intentional\n' >&2; exit 1; }
fi

printf 'ok - %s completed\n' "${AGENTS_MODES_TIER:-live tests}"
