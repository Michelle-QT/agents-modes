#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
: "${TEST_TMP_ROOT:?tests/run.sh must set TEST_TMP_ROOT}"

fail() {
  printf 'not ok: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '# %s\n' "$*" >&2
}

record_skip() {
  local reason="$*"
  printf 'skip: %s\n' "$reason" >&2
  mkdir -p "$TEST_TMP_ROOT"
  printf '%s\t%s\n' "${AGENTS_MODES_TIER:-tests}" "$reason" >> "$TEST_TMP_ROOT/skips.tsv"
}

agent_case_selected() {
  local target="$1"
  local mode="$2"
  local case_name="$3"
  local only=" ${4:-} "
  local skipped=" ${5:-} "
  case "$skipped" in
    *" $target-$mode "*|*" $target-$mode:$case_name "*) return 1 ;;
  esac
  [ "$only" = "  " ] && return 0
  case "$only" in
    *" $target-$mode "*|*" $target-$mode:$case_name "*) return 0 ;;
    *) return 1 ;;
  esac
}

skip() {
  record_skip "$*"
  exit 0
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

tmp_dir() {
  mkdir -p "$TEST_TMP_ROOT"
  mktemp -d "$TEST_TMP_ROOT/$1.XXXXXX"
}

assert_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

assert_executable() {
  [ -x "$1" ] || fail "not executable: $1"
}

assert_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$file" || fail "$file does not contain: $needle"
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  # A missing file makes grep exit 2, which is indistinguishable from "not found"
  # unless we check first; without this, an assertion against a deleted path passes.
  [ -f "$file" ] || fail "missing file: $file"
  if grep -Fq -- "$needle" "$file"; then
    fail "$file unexpectedly contains: $needle"
  fi
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  local what="${3:-value}"
  if [ "$actual" != "$expected" ]; then
    fail "$what: expected [$expected], got [$actual]"
  fi
}

assert_success() {
  local out
  out="$(tmp_dir assert-success)"
  if ! "$@" >"$out/stdout" 2>"$out/stderr"; then
    printf 'stdout:\n' >&2
    sed -n '1,120p' "$out/stdout" >&2 || true
    printf 'stderr:\n' >&2
    sed -n '1,120p' "$out/stderr" >&2 || true
    fail "command failed: $*"
  fi
}

assert_failure() {
  local out
  out="$(tmp_dir assert-failure)"
  if "$@" >"$out/stdout" 2>"$out/stderr"; then
    printf 'stdout:\n' >&2
    sed -n '1,120p' "$out/stdout" >&2 || true
    printf 'stderr:\n' >&2
    sed -n '1,120p' "$out/stderr" >&2 || true
    fail "command unexpectedly succeeded: $*"
  fi
}

assert_output_contains() {
  local expected="$1"
  shift
  local out
  out="$(tmp_dir assert-output)"
  if ! "$@" >"$out/stdout" 2>"$out/stderr"; then
    printf 'stdout:\n' >&2
    sed -n '1,120p' "$out/stdout" >&2 || true
    printf 'stderr:\n' >&2
    sed -n '1,120p' "$out/stderr" >&2 || true
    fail "command failed: $*"
  fi
  grep -Fq -- "$expected" "$out/stdout" || fail "output did not contain: $expected"
}

agent_structured_final_message_has() {
  local output_dir="$1"
  local expected="$2"
  jq -e -s --arg expected "$expected" '
    [.[] | select(.type == "result") | .result] | last == $expected
  ' "$output_dir/stdout" >/dev/null 2>&1
}

agent_structured_attempt_has() {
  local target="$1"
  local output_dir="$2"
  local kind="$3"
  local expected="$4"
  case "$target:$kind" in
    claude:shell)
      jq -e --arg expected "$expected" '
        select(.type == "assistant")
        | .message.content[]?
        | select(.type == "tool_use" and (.name == "Bash" or .name == "Shell"))
        | (.input.command // .input.cmd // "")
        | contains($expected)
      ' "$output_dir/stdout" >/dev/null 2>&1
      ;;
    claude:read)
      jq -e --arg expected "$expected" '
        select(.type == "assistant")
        | .message.content[]?
        | select(.type == "tool_use" and .name == "Read")
        | (.input.file_path // .input.path // "")
        | contains($expected)
      ' "$output_dir/stdout" >/dev/null 2>&1
      ;;
    codex:shell)
      jq -e --arg expected "$expected" '
        select((.type == "item.started" or .type == "item.completed")
          and .item.type == "command_execution")
        | (.item.command // "")
        | tostring
        | contains($expected)
      ' "$output_dir/stdout" >/dev/null 2>&1
      ;;
    *)
      return 2
      ;;
  esac
}

agent_structured_denial_has() {
  local target="$1"
  local output_dir="$2"
  case "$target" in
    claude)
      jq -e '
        select(.type == "user")
        | .message.content[]?
        | select(.type == "tool_result" and .is_error == true)
        | (.content | if type == "string" then . else tostring end)
        | test("requires approval|permission denied|operation not permitted"; "i")
      ' "$output_dir/stdout" >/dev/null 2>&1
      ;;
    codex)
      jq -e '
        select(.type == "item.completed" and .item.type == "command_execution")
        | select(.item.status == "failed" or ((.item.exit_code // 0) != 0))
      ' "$output_dir/stdout" >/dev/null 2>&1
      ;;
    *)
      return 2
      ;;
  esac
}

agent_codex_pre_execution_block_has() {
  local output_dir="$1"
  [ -f "$output_dir/last-message.txt" ] \
    && grep -Fxq -- "AGENTS_MODES_LIVE_BLOCKED_OR_PROMPTED" "$output_dir/last-message.txt" \
    && jq -e -s '
      any(.[]; .type == "turn.completed")
      and all(.[];
        .type != "turn.failed"
        and .type != "error"
        and (((.type == "item.started" or .type == "item.completed")
          and .item.type == "command_execution") | not))
    ' "$output_dir/stdout" >/dev/null 2>&1
}

dump_agent_output() {
  local output_dir="$1"
  printf 'stdout:\n' >&2
  sed -n '1,160p' "$output_dir/stdout" >&2 || true
  printf 'stderr:\n' >&2
  sed -n '1,160p' "$output_dir/stderr" >&2 || true
  if [ -f "$output_dir/last-message.txt" ]; then
    printf 'last message:\n' >&2
    sed -n '1,160p' "$output_dir/last-message.txt" >&2 || true
  fi
}

agent_output_files_exist() {
  local output_dir="$1"
  [ -f "$output_dir/stdout" ] && [ -f "$output_dir/stderr" ]
}

agent_output_has() {
  local output_dir="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$output_dir/stdout" 2>/dev/null && return 0
  grep -Fq -- "$needle" "$output_dir/stderr" 2>/dev/null && return 0
  [ -f "$output_dir/last-message.txt" ] && grep -Fq -- "$needle" "$output_dir/last-message.txt" 2>/dev/null && return 0
  return 1
}

agent_infra_failed() {
  local output_dir="$1"
  for needle in \
    "Not logged in" \
    "401 Unauthorized" \
    "Missing bearer" \
    "failed to lookup address information" \
    "error sending request" \
    "stream disconnected before completion" \
    "API Error: 529 Overloaded" \
    '"api_error_status":529' \
    '"error_status":529' \
    "Selected model is at capacity. Please try a different model." \
    "unbound variable"; do
    agent_output_has "$output_dir" "$needle" && return 0
  done
  return 1
}

validate_agent_negative_status() {
  local target="$1"
  local output_dir="$2"
  local kind="$3"
  local expected="$4"
  local label="$5"
  local status="$6"
  [ "$status" -ne 124 ] || fail "$label timed out"
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  if agent_infra_failed "$output_dir"; then
    if agent_structured_attempt_has "$target" "$output_dir" "$kind" "$expected"; then
      note "$label reached the matching tool attempt before a provider failure"
      return 0
    fi
    dump_agent_output "$output_dir"
    fail "$label failed before reaching the permission check"
  fi
  dump_agent_output "$output_dir"
  fail "$label agent session failed with status $status"
}

reject_pre_attempt_infra_failure() {
  local target="$1"
  local output_dir="$2"
  local kind="$3"
  local expected="$4"
  local label="$5"
  if agent_infra_failed "$output_dir" \
    && ! agent_structured_attempt_has "$target" "$output_dir" "$kind" "$expected"; then
    dump_agent_output "$output_dir"
    fail "$label failed before reaching the permission check"
  fi
}

stop_process_group() {
  local pid="$1"
  # The caller starts each agent as its own process group. TERM reaches both the agent
  # and its launcher, allowing the launcher's EXIT trap to remove the Research container.
  # The caller cancels this watcher as soon as wait returns, so KILL is only reached when
  # the group did not finish its cleanup during the grace period.
  kill -s TERM -- "-$pid" 2>/dev/null || true
  sleep 10
  kill -s KILL -- "-$pid" 2>/dev/null || true
}

run_with_timeout() {
  local seconds="$1"
  shift
  local pid watcher status timeout_dir timeout_file
  timeout_dir="$(tmp_dir agent-timeout)"
  timeout_file="$timeout_dir/expired"
  python3 "$ROOT/tests/process-group-exec.py" "$@" &
  pid=$!
  (
    sleep "$seconds"
    if kill -0 "$pid" 2>/dev/null; then
      : > "$timeout_file"
      stop_process_group "$pid"
    fi
  ) &
  watcher=$!
  if wait "$pid"; then
    status=0
  else
    status=$?
  fi
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  [ ! -f "$timeout_file" ] || return 124
  return "$status"
}

run_with_timeout_until_denial() {
  local seconds="$1"
  local target="$2"
  local output_dir="$3"
  local kind="$4"
  local expected="$5"
  shift 5
  [ "${1:-}" = "--" ] || return 2
  shift
  local pid denial_watcher timeout_watcher status state_dir denial_file timeout_file
  state_dir="$(tmp_dir agent-monitored)"
  denial_file="$state_dir/denied"
  timeout_file="$state_dir/expired"
  python3 "$ROOT/tests/process-group-exec.py" "$@" &
  pid=$!
  (
    while kill -0 "$pid" 2>/dev/null; do
      if agent_structured_attempt_has "$target" "$output_dir" "$kind" "$expected" \
        && agent_structured_denial_has "$target" "$output_dir"; then
        : > "$denial_file"
        stop_process_group "$pid"
        exit 0
      fi
      sleep 0.2
    done
  ) &
  denial_watcher=$!
  (
    sleep "$seconds"
    if kill -0 "$pid" 2>/dev/null; then
      : > "$timeout_file"
      stop_process_group "$pid"
    fi
  ) &
  timeout_watcher=$!
  if wait "$pid"; then
    status=0
  else
    status=$?
  fi
  kill "$denial_watcher" "$timeout_watcher" 2>/dev/null || true
  wait "$denial_watcher" 2>/dev/null || true
  wait "$timeout_watcher" 2>/dev/null || true
  [ ! -f "$denial_file" ] || return 0
  [ ! -f "$timeout_file" ] || return 124
  return "$status"
}
