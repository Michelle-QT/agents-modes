#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
: "${TEST_TMP_ROOT:=$(mktemp -d "${TMPDIR:-/tmp}/agents-modes-tests.XXXXXX")}"
export TEST_TMP_ROOT
unset AGENTS_CLAUDE_MODE AGENTS_CODEX_MODE CODEX_HOME CODEX_SANDBOX CODEX_SQLITE_HOME RUNBOX_CONTAINER

cleanup() {
  if [ "${KEEP_TEST_TMP:-0}" = "1" ]; then
    printf '# keeping test temp dir: %s\n' "$TEST_TMP_ROOT" >&2
  else
    rm -rf "$TEST_TMP_ROOT"
  fi
}
trap cleanup EXIT

for test_script in "$ROOT"/tests/test-*.sh; do
  printf '==> %s\n' "$(basename "$test_script")"
  bash "$test_script"
done

printf 'ok - offline mode tests passed\n'
