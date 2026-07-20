#!/usr/bin/env bash
set -euo pipefail

# Asserts that the installed Codex profiles deliver the table's cells, by running shell
# commands inside Codex's real seatbelt sandbox. No agent, no tokens.
#
# The case list is generated from the coverage rows in modes.json (runner=seatbelt), so
# this file owns only the fixtures and the assertion; hand-enumerated case lists are the
# drift pattern that let cells go untested.
#
# Codex cannot apply a seatbelt profile from inside another sandbox, so this file skips
# when run from within an agent session and does its work on a bare host.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require_cmd git
require_cmd python3
command -v codex >/dev/null 2>&1 || skip "codex not on PATH"
[ -z "${AGENTS_MODES_OUTER_CODEX_SANDBOX:-}${AGENTS_MODES_OUTER_CLAUDE_MODE:-}" ] \
  || skip "codex cannot apply a sandbox from inside another sandbox; run this on a bare host"

prefix="$(tmp_dir codex-sandbox)"
codex_home="$prefix/codex"
share="$prefix/share"
make -C "$ROOT" codex BINDIR="$prefix/bin" CODEXHOME="$codex_home" \
  AGENTS_SHAREDIR="$share" CONTAINER_SHAREDIR="$share/container" >/dev/null

# A non-secret home file, so the read cell's home leg has something real to probe:
# readable in the host-read modes, denied under Research's ":minimal".
home_probe="$HOME/.agents-modes-seatbelt-probe"
cleanup_home_probe() {
  rm -f "$home_probe"
}
trap cleanup_home_probe EXIT
printf 'agents-modes seatbelt probe\n' > "$home_probe"
export AGENTS_MODES_SEATBELT_HOME_PROBE="$home_probe"

work="$(tmp_dir codex-sandbox-project)"
mkdir -p "$work/nested"
cd "$work"
git init -q .
git config user.email test@example.invalid
git config user.name test
printf 'public\n' > nested/readme.txt
printf 'ROOT_SECRET\n' > .env
printf 'NESTED_SECRET\n' > nested/.env
printf 'PEM_SECRET\n' > nested/key.pem
printf 'KEY_SECRET\n' > nested/id_rsa
git add -A
git commit -qm init

# Exit status of a command run inside <profile>'s sandbox.
sandboxed() {
  local profile="$1" command="$2"
  local mode="${profile#agents-}"
  (
    cd "$work"
    export CODEX_HOME="$codex_home"
    export AGENTS_MODES_DIR="$share"
    # shellcheck source=/dev/null
    . "$prefix/bin/codex-launcher-session.sh"
    codex_start_mode_session "$mode" "$profile" \
      "$share/codex/profiles/$profile.config.toml" \
      "$share/codex/config/$mode.config.toml" \
      "$share/codex/rules/agents-modes.rules" \
      "$prefix/bin" \
      "$(jq -r '.targets.codex.run_as_user.executable' "$ROOT/modes.json")"
    trap codex_stop_mode_session EXIT
    codex --profile "$profile" sandbox -- sh -c "$command" >/dev/null 2>&1
  )
  echo "$?"
}

assert_sandbox() {
  local profile="$1" command="$2" want="$3" what="$4"
  local got
  got="$(sandboxed "$profile" "$command")"
  if [ "$want" = "allow" ]; then
    [ "$got" = "0" ] || fail "$profile: $what should be allowed, got exit $got"
  else
    [ "$got" != "0" ] || fail "$profile: $what should be denied, but it succeeded"
  fi
}

seatbelt_case() {
  assert_sandbox "$1" "$2" "$3" "$4"
}

note "running generated seatbelt cases derived from modes.json"
seatbelt_cases="$(tmp_dir seatbelt-cases)/seatbelt-cases.sh"
python3 "$ROOT/tools/agents-modes-gen" seatbelt-cases-sh --output "$seatbelt_cases"
# shellcheck source=/dev/null
. "$seatbelt_cases"

printf 'ok - codex sandbox semantics match the table\n'
