#!/usr/bin/env bash
set -euo pipefail

# Experimental driver for real Codex TUI approval prompts. This spends tokens and must run on a bare host:
# non-interactive Codex cannot witness approvals, and nested sandboxes cannot exercise the
# same run_as_user MCP approval path a user accepts in the TUI.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require_cmd expect
require_cmd git
require_cmd jq
require_cmd make
command -v codex >/dev/null 2>&1 || skip "codex not on PATH"
[ -z "${AGENTS_MODES_OUTER_CODEX_SANDBOX:-}${AGENTS_MODES_OUTER_CLAUDE_MODE:-}" ] \
  || skip "codex approval tests must run on a bare host, not inside another sandbox"

approval_timeout="${AGENTS_MODES_APPROVAL_TIMEOUT:-360}"
approval_prompt_timeout="${AGENTS_MODES_APPROVAL_PROMPT_TIMEOUT:-75}"
approval_post_timeout="${AGENTS_MODES_APPROVAL_POST_TIMEOUT:-45}"
approval_accept_keys="${AGENTS_MODES_CODEX_APPROVAL_ACCEPT_KEYS:-1\\r}"
approval_deny_keys="${AGENTS_MODES_CODEX_APPROVAL_DENY_KEYS:-2\\r}"
agent_only=" ${AGENTS_MODES_LIVE_ONLY:-} "
outside_guard_dirs=()

shell_quote() {
  printf '%q' "$1"
}

physical_path() {
  (cd "$1" && pwd -P)
}

prefix="$(tmp_dir approvals)"
bindir="$prefix/bin"
share="$prefix/share"
codex_home="$prefix/codex"
container_share="$share/container"

cleanup_approval_outside_dirs() {
  local dir
  if [ "${KEEP_TEST_TMP:-0}" = "1" ]; then
    for dir in "${outside_guard_dirs[@]}"; do
      printf '# keeping approval outside dir: %s\n' "$dir" >&2
    done
  else
    for dir in "${outside_guard_dirs[@]}"; do
      rm -rf "$dir"
    done
  fi
}
trap cleanup_approval_outside_dirs EXIT

make -C "$ROOT" codex BINDIR="$bindir" CODEXHOME="$codex_home" \
  AGENTS_SHAREDIR="$share" CONTAINER_SHAREDIR="$container_share" >/dev/null

auth_home="${AGENTS_MODES_LIVE_CODEX_AUTH_HOME:-${CODEX_HOME:-$HOME/.codex}}"
export AGENTS_MODES_CODEX_AUTH_HOME="$auth_home"

expect_driver="$prefix/codex-approval.expect"
cat > "$expect_driver" <<'EXPECT'
set timeout $env(AGENTS_MODES_APPROVAL_TIMEOUT)
log_file -noappend $env(AGENTS_MODES_APPROVAL_LOG)
set keys [subst -nocommands -novariables $env(AGENTS_MODES_APPROVAL_KEYS)]
set decision $env(AGENTS_MODES_APPROVAL_DECISION)
set prompt_timeout $env(AGENTS_MODES_APPROVAL_PROMPT_TIMEOUT)
set post_timeout $env(AGENTS_MODES_APPROVAL_POST_TIMEOUT)
set saw_prompt 0

spawn -noecho {*}$argv
set timeout $prompt_timeout

proc probe_files_exist {} {
  expr {[file exists $::env(AGENTS_MODES_APPROVAL_OUTSIDE_FILE)] && [file exists $::env(AGENTS_MODES_APPROVAL_MARKER_FILE)]}
}

proc probe_any_file_exists {} {
  expr {[file exists $::env(AGENTS_MODES_APPROVAL_OUTSIDE_FILE)] || [file exists $::env(AGENTS_MODES_APPROVAL_MARKER_FILE)]}
}

proc finish_success {} {
  send -- "\003"
  exit 0
}

proc wait_accept {} {
  set deadline [expr {[clock milliseconds] + ($::post_timeout * 1000)}]
  while {[clock milliseconds] < $deadline} {
    if {[probe_files_exist]} {
      finish_success
    }
    expect {
      -timeout 1 {}
      -re {AGENTS_MODES_APPROVAL_DENIED|denied|Denied|not approved|rejected|cancelled|canceled|refused} {
        exit 21
      }
      eof {
        exit 11
      }
    }
  }
  exit 12
}

proc wait_deny {} {
  set deadline [expr {[clock milliseconds] + ($::post_timeout * 1000)}]
  while {[clock milliseconds] < $deadline} {
    if {[probe_any_file_exists]} {
      exit 22
    }
    expect {
      -timeout 1 {}
      -re {AGENTS_MODES_APPROVAL_DENIED|denied|Denied|not approved|rejected|cancelled|canceled|refused} {
        finish_success
      }
      eof {
        if {[probe_any_file_exists]} {
          exit 22
        }
        exit 0
      }
    }
  }
  exit 13
}

expect {
  -re {needs your approval|requires approval|Allow Codex to run|Do you want to approve|Allow the .* MCP server to run tool} {
    if {$saw_prompt == 0} {
      set saw_prompt 1
      send -- $keys
      if {$decision eq "accept"} {
        wait_accept
      } else {
        wait_deny
      }
    }
    exp_continue
  }
  -re {AGENTS_MODES_APPROVAL_ACCEPTED|AGENTS_MODES_APPROVAL_DENIED} {
    if {$saw_prompt == 0} {
      exit 20
    }
    send -- "\003"
    exit 0
  }
  -re {Not logged in|401 Unauthorized|Missing bearer|error sending request|failed to lookup address information|stream disconnected before completion} {
    exit 30
  }
  -re {Do you trust the contents of this directory|Trusting the directory allows project-local config} {
    exit 40
  }
  -re {Operation not permitted|Permission denied|Read-only file system|network denied|Network is unreachable} {
    if {$saw_prompt == 0} {
      exit 23
    }
    exp_continue
  }
  timeout {
    exit 10
  }
  eof {
    exit 11
  }
}
EXPECT

new_outside_file() {
  local name="$1"
  local output_var="$2"
  local base dir path
  for base in "${AGENTS_MODES_LIVE_OUTSIDE_BASE:-}" /private/var/tmp "$HOME"; do
    [ -n "$base" ] || continue
    [ -d "$base" ] || continue
    dir="$(mktemp -d "$base/agents-modes-approval.XXXXXX" 2>/dev/null || true)"
    [ -n "$dir" ] || continue
    outside_guard_dirs+=("$dir")
    path="$dir/$name.txt"
    printf -v "$output_var" '%s' "$path"
    return 0
  done
  fail "could not create outside-workspace approval probe path"
}

new_workdir() {
  local name="$1"
  local work
  work="$(tmp_dir "$name")"
  git init -q "$work"
  printf 'marker\n' > "$work/marker.txt"
  work="$(physical_path "$work")"
  printf '%s\n' "$work"
}

write_probe_script() {
  local work="$1"
  local outside_file="$2"
  local marker="$3"
  local script="$work/approval-probe.sh"
  {
    printf '#!/bin/sh\n'
    printf 'set -eu\n'
    printf 'printf approval > %s\n' "$(shell_quote "$outside_file")"
    printf 'printf approval > %s\n' "$(shell_quote "$marker")"
  } > "$script"
  chmod 0700 "$script"
}

host_user_id() {
  id -u
}

file_owner_id() {
  stat -f '%u' "$1" 2>/dev/null || stat -c '%u' "$1"
}

approval_prompt() {
  local label="$1"
  local command="$2"
  local working_directory="$3"
  printf 'Run this local verification command for %s.\n' "$label"
  printf 'First use tool_search exactly once to discover and load run_as_user; that discovery call is required.\n'
  printf 'Then call the run_as_user MCP tool exactly once with working_directory="%s".\n' "$working_directory"
  printf 'Do not write prose before that tool call, and do not infer the user choice yourself.\n'
  printf 'Use the run_as_user tool to run the command inside the fence below.\n'
  printf 'Pass the command through verbatim as one shell command.\n'
  printf -- '---8<---\n'
  printf '%s\n' "$command"
  printf -- '--->8---\n'
  printf 'Do not use shell or file tools, do not retry a cancelled call, and do not try an alternative.\n'
  printf 'After the run_as_user tool returns or is cancelled, stop without summarizing.\n'
}

should_run_approval_case() {
  local target="$1"
  local mode="$2"
  local case_name="$3"
  local decision="$4"
  [ "$agent_only" = "  " ] && return 0
  case "$agent_only" in
    *" $target-$mode "*|*" $target-$mode:$case_name "*|*" $target-$mode:$case_name-$decision "*) return 0 ;;
    *) return 1 ;;
  esac
}

research_prereq_ok() {
  (
    export AGENTS_CONTAINER_DIR="$container_share"
    export AGENTS_DOCKER_CONFIG="$prefix/docker-config"
    # shellcheck source=/dev/null
    . "$container_share/boxlib.sh"
    _box_set_docker_config
    docker_bin="$(_box_find_docker)" || return 1
    "$docker_bin" info >/dev/null 2>&1 || return 1
    if ! "$docker_bin" image inspect agents-box:base >/dev/null 2>&1; then
      [ "${AGENTS_MODES_LIVE_BUILD:-0}" = "1" ] || return 1
    fi
  )
}

run_codex_approval_case() {
  local mode="$1"
  local case_name="$2"
  local decision="$3"
  local run_id outside_file work marker command prompt log status keys launcher
  should_run_approval_case codex "$mode" "$case_name" "$decision" || return 0
  if [ "$mode" = "research" ] && ! research_prereq_ok; then
    record_skip "codex-$mode:$case_name-$decision: Docker is unavailable or agents-box:base is missing without AGENTS_MODES_LIVE_BUILD=1"
    return 0
  fi

  run_id="codex-$mode-probe-$RANDOM-$RANDOM"
  new_outside_file "$run_id" outside_file
  work="$(new_workdir "$run_id")"
  marker="$run_id.txt"
  write_probe_script "$work" "$outside_file" "$marker"
  command="./approval-probe.sh"
  prompt="$(approval_prompt "case-$RANDOM" "$command" "$work")"
  log="$prefix/codex-$mode-$decision.log"
  launcher="$bindir/codex-$mode"
  case "$decision" in
    accept) keys="$approval_accept_keys" ;;
    deny) keys="$approval_deny_keys" ;;
    *) fail "unknown approval decision: $decision" ;;
  esac

  note "calling codex-$mode:$case_name-$decision"
  status=0
  (
    cd "$work"
    PATH="$bindir:$PATH" \
    CODEX_HOME="$codex_home" \
    AGENTS_MODES_DIR="$share" \
    AGENTS_CONTAINER_DIR="$container_share" \
    AGENTS_MODES_APPROVAL_TIMEOUT="$approval_timeout" \
    AGENTS_MODES_APPROVAL_PROMPT_TIMEOUT="$approval_prompt_timeout" \
    AGENTS_MODES_APPROVAL_POST_TIMEOUT="$approval_post_timeout" \
    AGENTS_MODES_APPROVAL_DECISION="$decision" \
    AGENTS_MODES_APPROVAL_KEYS="$keys" \
    AGENTS_MODES_APPROVAL_LOG="$log" \
    AGENTS_MODES_APPROVAL_OUTSIDE_FILE="$outside_file" \
    AGENTS_MODES_APPROVAL_MARKER_FILE="$work/$marker" \
      expect "$expect_driver" "$launcher" --no-alt-screen "$prompt"
  ) || status=$?

  if [ "$status" -ne 0 ]; then
    sed -n '1,220p' "$log" >&2 || true
    fail "codex-$mode:$case_name-$decision did not complete the approval flow (expect status $status)"
  fi

  if [ "$decision" = "deny" ]; then
    [ ! -e "$outside_file" ] || fail "codex-$mode:$case_name-deny wrote outside file after denial: $outside_file"
    [ ! -e "$work/$marker" ] || fail "codex-$mode:$case_name-deny wrote workspace marker after denial: $work/$marker"
  else
    [ -f "$outside_file" ] || fail "codex-$mode:$case_name-accept did not write outside file"
    [ -f "$work/$marker" ] || fail "codex-$mode:$case_name-accept did not write workspace marker"
    assert_equals "$(cat "$outside_file")" "approval" "outside file content"
    assert_equals "$(cat "$work/$marker")" "approval" "workspace marker content"
    assert_equals "$(file_owner_id "$outside_file")" "$(host_user_id)" "outside file owner"
    assert_equals "$(file_owner_id "$work/$marker")" "$(host_user_id)" "workspace marker owner"
  fi
  note "ok codex-$mode:$case_name-$decision"
}

note "experimentally driving Codex outside -> prompt accept and deny behavior"
approval_cases="$(tmp_dir approval-cases)/approval-cases.sh"
python3 "$ROOT/tools/agents-modes-gen" approval-cases-sh --output "$approval_cases"
# shellcheck source=/dev/null
. "$approval_cases"

printf 'ok - experimental Codex approval prompt driver completed\n'
