#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require_cmd jq
require_cmd make
require_cmd python3

note "checking shell syntax"
modes="$(python3 "$ROOT/tools/agents-modes-gen" mode-list)"
scripts=(
  claude/bin/claude-mode
  claude/helpers/claude-launcher-settings.sh
  codex/bin/codex-mode
  codex/helpers/codex-launcher-dispatch.sh
  codex/helpers/codex-launcher-session.sh
  codex/helpers/codex-dispatch-client.sh
  container/boxlib.sh
  container/runbox
  helpers/sandbox-escape
  modes/development/fetch-all
  modes/development/gh-ro
  modes/development/ls-remote
  tests/agent-modes.sh
  tests/lib.sh
  tests/live-approvals.sh
  tests/live-codex-sandbox.sh
  tests/live-docker.sh
  tests/live-network.sh
  tests/live-witness.sh
  tests/network-read-write
  tests/run.sh
  tests/run-live.sh
  tests/test-helpers.sh
  tests/test-install.sh
  tests/test-static.sh
  tests/test-table.sh
  tests/test-symmetry.sh
)
for script in "${scripts[@]}"; do
  bash -n "$ROOT/$script"
done

# What each settings file and profile must CONTAIN is asserted by test-table.sh, against
# the installed artifacts and against modes.json. This file checks only that the
# generator is well-formed and that its output parses on both targets.
note "checking the generator lints its own table"
tmp="$(tmp_dir static)"
assert_success python3 "$ROOT/tools/agents-modes-gen" lint

note "checking generated Claude settings are valid JSON"
for mode in $modes; do
  python3 "$ROOT/tools/agents-modes-gen" claude-settings "$mode" > "$tmp/$mode.json" \
    || fail "generator failed for claude-settings $mode"
  python3 "$ROOT/tools/agents-modes-gen" claude-mcp-config "$mode" > "$tmp/$mode.mcp.json" \
    || fail "generator failed for claude-mcp-config $mode"
  jq empty "$tmp/$mode.json" || fail "generated $mode.json is not valid JSON"
  jq empty "$tmp/$mode.mcp.json" || fail "generated $mode.mcp.json is not valid JSON"
done

note "checking the generator refuses an unknown mode rather than emitting nothing"
assert_failure python3 "$ROOT/tools/agents-modes-gen" claude-settings no-such-mode

note "checking Claude subagent prompt propagation"
launcher="$ROOT/claude/bin/claude-mode"
assert_contains "$launcher" '--append-subagent-system-prompt'
assert_contains "$launcher" 'claude-launcher-settings.sh'
assert_contains "$launcher" 'claude_validate_mode_args "$@"'
assert_contains "$launcher" 'claude_prepare_session_settings "$settings" session_settings'
assert_contains "$launcher" '--settings "$session_settings"'
assert_contains "$launcher" 'claude_args+=(--fork-session)'
assert_contains "$launcher" '.needs_container'
# The renderer must absolutize every ./ guard, not a per-path list of them: the forbidden
# row is data, and a guard added there but not here would fail open. Pin the absence of
# the old per-path jq arguments, not of the path names, which the comments cite.
assert_contains "$ROOT/claude/helpers/claude-launcher-settings.sh" 'def absolutize:'
assert_not_contains "$ROOT/claude/helpers/claude-launcher-settings.sh" '--arg escapes'
assert_not_contains "$ROOT/claude/helpers/claude-launcher-settings.sh" '--arg container'

note "checking launcher policy-override guards"
# shellcheck source=/dev/null
. "$ROOT/claude/helpers/claude-launcher-settings.sh"
assert_failure claude_validate_mode_args --settings hostile.json
assert_failure claude_validate_mode_args --plugin-dir=hostile-plugin
assert_failure claude_validate_mode_args --permission-mode bypassPermissions
assert_failure claude_validate_mode_args --add-dir /private/var/tmp
assert_failure claude_validate_mode_args --fork-session
assert_failure claude_validate_mode_args --resume prior-session --permission-mode bypassPermissions
assert_failure claude_validate_mode_args plugin list
assert_failure claude_validate_mode_args --model sonnet plugin list
assert_success claude_validate_mode_args --resume prior-session
assert_equals "$claude_mode_resume" "1" "Claude resume detection"
assert_success claude_validate_mode_args --resume plugin
assert_success claude_validate_mode_args --resume prior-session plugin
assert_success claude_validate_mode_args --resume=prior-session
assert_success claude_validate_mode_args --resume=prior-session mcp
assert_success claude_validate_mode_args -rprior-session
assert_success claude_validate_mode_args --continue
assert_success claude_validate_mode_args --continue agents
assert_success claude_validate_mode_args -c
assert_success claude_validate_mode_args -p plugin
assert_success claude_validate_mode_args -- plugin
assert_success claude_validate_mode_args --model plugin -p "ordinary prompt"
assert_success claude_validate_mode_args --model sonnet --output-format stream-json -p "ordinary prompt"
assert_success claude_validate_mode_args --fallback-model sonnet,haiku -p "ordinary prompt"
# shellcheck source=/dev/null
. "$ROOT/codex/helpers/codex-launcher-session.sh"
assert_equals "$(codex_toml_string $'line\n"quote"\\tail')" '"line\n\"quote\"\\tail"' "Codex TOML string encoding"
assert_failure codex_validate_mode_args --config 'sandbox_mode="danger-full-access"'
assert_failure codex_validate_mode_args '-csandbox_mode="danger-full-access"'
assert_failure codex_validate_mode_args --sandbox=danger-full-access
assert_failure codex_validate_mode_args --profile hostile
assert_failure codex_validate_mode_args --add-dir /private/var/tmp
assert_failure codex_validate_mode_args --image /private/var/tmp/outside.png
assert_failure codex_validate_mode_args --oss
assert_failure codex_validate_mode_args plugin list
assert_failure codex_validate_mode_args --model gpt-5.5 plugin list
assert_failure codex_validate_mode_args resume --sandbox danger-full-access
assert_failure codex_validate_mode_args debug
assert_failure codex_validate_mode_args debug doctor
assert_failure codex_validate_mode_args debug prompt-input --config 'sandbox_mode="danger-full-access"'
assert_success codex_validate_mode_args resume prior-session
assert_success codex_validate_mode_args resume --last
assert_success codex_validate_mode_args debug prompt-input
assert_success codex_validate_mode_args debug prompt-input "ordinary prompt"
assert_success codex_validate_mode_args --model plugin exec "ordinary prompt"
assert_success codex_validate_mode_args --model gpt-5.5 --json --ephemeral "ordinary prompt"
assert_success codex_validate_mode_args exec --json --ephemeral "ordinary prompt"
assert_success codex_validate_mode_args exec resume --last "ordinary prompt"
assert_success codex_validate_mode_args exec --json help
assert_success codex_validate_mode_args -- help
weird_path=$'line\n"quote"\\tail'
python3 "$ROOT/tools/agents-modes-gen" codex-profile development > "$tmp/weird-source.config.toml"
codex_render_session_profile "$tmp/weird-source.config.toml" \
  '[permissions.agents-development.filesystem]' \
  "$weird_path/session" "$weird_path/auth" "$weird_path/project" \
  "$weird_path/config" "$weird_path/helpers" > "$tmp/weird-rendered.config.toml"
python3 - "$tmp/weird-rendered.config.toml" "$weird_path" <<'PY'
import pathlib
import sys
import tomllib

parsed = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
root = sys.argv[2]
filesystem = parsed["permissions"]["agents-development"]["filesystem"]
assert root + "/session" not in filesystem
assert filesystem[root + "/auth"] == "deny"
assert filesystem[root + "/config"] == "read"
assert filesystem[root + "/helpers"] == "read"
assert parsed["projects"][root + "/project"]["trust_level"] == "untrusted"
PY

missing_parent="$tmp/missing-policy-parent"
mkdir -p "$missing_parent/project"
(
  cd "$missing_parent/project"
  codex_render_session_profile "$tmp/weird-source.config.toml" \
    '[permissions.agents-development.filesystem]' \
    "$missing_parent/session" "$missing_parent/auth" "$missing_parent/project" \
    "$missing_parent/config" "$missing_parent/helpers"
) > "$missing_parent/without-parent.config.toml"
mkdir -p "$missing_parent/project/.claude"
(
  cd "$missing_parent/project"
  codex_render_session_profile "$tmp/weird-source.config.toml" \
    '[permissions.agents-development.filesystem]' \
    "$missing_parent/session" "$missing_parent/auth" "$missing_parent/project" \
    "$missing_parent/config" "$missing_parent/helpers"
) > "$missing_parent/with-parent.config.toml"
python3 - "$missing_parent/without-parent.config.toml" "$missing_parent/with-parent.config.toml" <<'PY'
import pathlib
import sys
import tomllib

without_parent = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
with_parent = tomllib.loads(pathlib.Path(sys.argv[2]).read_text())
table = "agents-development"
without_fs = without_parent["permissions"][table]["filesystem"][":workspace_roots"]
with_fs = with_parent["permissions"][table]["filesystem"][":workspace_roots"]
assert ".claude/settings.json" not in without_fs
assert ".claude/settings.local.json" not in without_fs
assert with_fs[".claude/settings.json"] == "read"
assert with_fs[".claude/settings.local.json"] == "read"
PY

note "checking generated Codex TOML round-trips through a real parser"
for mode in $modes; do
  python3 "$ROOT/tools/agents-modes-gen" codex-profile "$mode" > "$tmp/agents-$mode.config.toml" \
    || fail "generator failed for codex-profile $mode"
  python3 "$ROOT/tools/agents-modes-gen" codex-session-config "$mode" > "$tmp/$mode.session.config.toml" \
    || fail "generator failed for codex-session-config $mode"
done
run_as_user_source="$(python3 "$ROOT/tools/agents-modes-gen" codex-run-as-user-source)"
run_as_user_executable="${run_as_user_source##*/}"
mkdir -p "$tmp/helpers"
install -m 0755 "$ROOT/$run_as_user_source" "$tmp/helpers/$run_as_user_executable"
: > "$tmp/invocation.environment"
codex_render_session_config \
  "$tmp/development.session.config.toml" "$tmp/helpers" "$run_as_user_executable" \
  "$tmp/invocation.environment" > "$tmp/development.rendered.config.toml"
python3 "$ROOT/tools/agents-modes-gen" codex-rules > "$tmp/agents-modes.rules" \
  || fail "generator failed for codex-rules"
python3 "$ROOT/tools/agents-modes-gen" container-policy-sh > "$tmp/policy.sh" \
  || fail "generator failed for container-policy-sh"
python3 "$ROOT/tools/agents-modes-gen" agent-cases-sh > "$tmp/agent-cases.sh" \
  || fail "generator failed for agent-cases-sh"
python3 "$ROOT/tools/agents-modes-gen" seatbelt-cases-sh > "$tmp/seatbelt-cases.sh" \
  || fail "generator failed for seatbelt-cases-sh"
python3 "$ROOT/tools/agents-modes-gen" witness-cases-sh > "$tmp/witness-cases.sh" \
  || fail "generator failed for witness-cases-sh"
bash -n "$tmp/policy.sh"
bash -n "$tmp/agent-cases.sh"
bash -n "$tmp/seatbelt-cases.sh"
bash -n "$tmp/witness-cases.sh"
assert_contains "$tmp/agent-cases.sh" "run_agent_check 'claude' 'research'"
assert_contains "$tmp/agent-cases.sh" "run_forbidden_write_check 'codex' 'development'"
[ "$(tail -n 1 "$tmp/agent-cases.sh")" = 'note "live agent sessions used: $agent_session_count"' ] \
  || fail "generated agent schedule reports its session count before the final cases"
assert_contains "$tmp/seatbelt-cases.sh" "seatbelt_case 'agents-research'"
assert_contains "$tmp/witness-cases.sh" "run_witness_case 'claude' 'development' 'outside-write' 'deny'"
assert_contains "$tmp/witness-cases.sh" "run_witness_case 'codex' 'research' 'host-shell' 'accept'"

note "checking structured live-agent evidence parsers"
assert_success agent_case_selected claude research positive "" ""
assert_success agent_case_selected claude research positive "claude-research" ""
assert_success agent_case_selected claude research positive "claude-research:positive" ""
assert_failure agent_case_selected claude research positive "codex-research" ""
assert_failure agent_case_selected claude research positive "" "claude-research:positive"
assert_failure agent_case_selected claude research positive "claude-research" "claude-research:positive"
cat > "$tmp/claude-events.jsonl" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"printf probe > marker"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/probe"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"This command requires approval","is_error":true}]}}
{"type":"result","result":"AGENTS_MODES_LIVE_BLOCKED_OR_PROMPTED"}
JSONL
cat > "$tmp/codex-events.jsonl" <<'JSONL'
{"type":"item.started","item":{"type":"command_execution","command":"bash -lc 'printf probe > marker'"}}
{"type":"item.completed","item":{"type":"command_execution","command":"bash -lc 'printf probe > marker'","aggregated_output":"permission denied","exit_code":1,"status":"failed"}}
JSONL
cat > "$tmp/codex-preflight-events.jsonl" <<'JSONL'
{"type":"thread.started","thread_id":"test"}
{"type":"turn.started"}
{"type":"item.completed","item":{"type":"agent_message","text":"AGENTS_MODES_LIVE_BLOCKED_OR_PROMPTED"}}
{"type":"turn.completed"}
JSONL
cat > "$tmp/codex-preflight-failed-events.jsonl" <<'JSONL'
{"type":"thread.started","thread_id":"test"}
{"type":"turn.started"}
{"type":"item.completed","item":{"type":"agent_message","text":"AGENTS_MODES_LIVE_BLOCKED_OR_PROMPTED"}}
{"type":"turn.failed","error":{"message":"Selected model is at capacity. Please try a different model."}}
JSONL
cat > "$tmp/codex-post-attempt-capacity-events.jsonl" <<'JSONL'
{"type":"thread.started","thread_id":"test"}
{"type":"turn.started"}
{"type":"item.started","item":{"type":"command_execution","command":"bash -lc 'printf probe > marker'","status":"in_progress"}}
{"type":"item.completed","item":{"type":"command_execution","command":"bash -lc 'printf probe > marker'","aggregated_output":"permission denied","exit_code":1,"status":"failed"}}
{"type":"error","message":"Selected model is at capacity. Please try a different model."}
{"type":"turn.failed","error":{"message":"Selected model is at capacity. Please try a different model."}}
JSONL
mkdir -p "$tmp/claude-output" "$tmp/codex-output" "$tmp/codex-preflight-output" "$tmp/codex-preflight-failed-output" "$tmp/codex-post-attempt-capacity-output"
cp "$tmp/claude-events.jsonl" "$tmp/claude-output/stdout"
cp "$tmp/codex-events.jsonl" "$tmp/codex-output/stdout"
cp "$tmp/codex-preflight-events.jsonl" "$tmp/codex-preflight-output/stdout"
cp "$tmp/codex-preflight-failed-events.jsonl" "$tmp/codex-preflight-failed-output/stdout"
cp "$tmp/codex-post-attempt-capacity-events.jsonl" "$tmp/codex-post-attempt-capacity-output/stdout"
touch "$tmp/codex-post-attempt-capacity-output/stderr"
printf 'AGENTS_MODES_LIVE_BLOCKED_OR_PROMPTED\n' > "$tmp/codex-preflight-output/last-message.txt"
printf 'AGENTS_MODES_LIVE_BLOCKED_OR_PROMPTED\n' > "$tmp/codex-preflight-failed-output/last-message.txt"
assert_success agent_structured_final_message_has "$tmp/claude-output" "AGENTS_MODES_LIVE_BLOCKED_OR_PROMPTED"
assert_success agent_structured_attempt_has claude "$tmp/claude-output" shell "printf probe > marker"
assert_success agent_structured_attempt_has claude "$tmp/claude-output" read "/tmp/probe"
assert_success agent_structured_denial_has claude "$tmp/claude-output"
assert_success agent_structured_attempt_has codex "$tmp/codex-output" shell "printf probe > marker"
assert_failure agent_structured_attempt_has codex "$tmp/codex-output" shell "different command"
assert_success agent_structured_denial_has codex "$tmp/codex-output"
assert_success agent_codex_pre_execution_block_has "$tmp/codex-preflight-output"
assert_failure agent_codex_pre_execution_block_has "$tmp/codex-preflight-failed-output"
assert_success agent_infra_failed "$tmp/codex-post-attempt-capacity-output"
assert_success validate_agent_negative_status codex "$tmp/codex-post-attempt-capacity-output" shell "printf probe > marker" codex-test 1
if (validate_agent_negative_status codex "$tmp/codex-preflight-failed-output" shell "printf probe > marker" codex-test 1) >/dev/null 2>&1; then
  fail "pre-attempt provider failure passed negative-status validation"
fi

cat > "$tmp/denial-process.sh" <<SH
#!/usr/bin/env bash
trap 'trap - TERM EXIT; printf cleaned > "$tmp/denial-process-cleaned"; exit 143' TERM EXIT
printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"printf probe > marker"}}]}}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","content":"This command requires approval","is_error":true}]}}'
sleep 60
:
SH
chmod +x "$tmp/denial-process.sh"
mkdir "$tmp/denial-process-output"
run_with_timeout_until_denial 5 claude "$tmp/denial-process-output" shell "printf probe > marker" -- \
  "$tmp/denial-process.sh" >"$tmp/denial-process-output/stdout" 2>"$tmp/denial-process-output/stderr" \
  || fail "structured denial did not terminate the agent process"
assert_file "$tmp/denial-process-cleaned"
fake_curl_dir="$tmp/fake-curl"
mkdir "$fake_curl_dir"
cat > "$fake_curl_dir/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGENTS_MODES_FAKE_CURL_LOG"
case "$*" in
  *https://example.com/*) printf 'Example Domain\n' ;;
  *https://httpbingo.org/anything*) exit 22 ;;
  *https://postman-echo.com/post*) printf '{"data":"agents-modes-live-web-write"}\n' ;;
  *) exit 22 ;;
esac
SH
chmod +x "$fake_curl_dir/curl"
network_marker="$tmp/network-read-write.marker"
AGENTS_MODES_FAKE_CURL_LOG="$tmp/fake-curl.log" PATH="$fake_curl_dir:$PATH" \
  "$ROOT/tests/network-read-write" "$network_marker"
assert_contains "$network_marker" "network-read-write"
assert_contains "$tmp/fake-curl.log" "https://httpbingo.org/anything"
assert_contains "$tmp/fake-curl.log" "https://postman-echo.com/post"
assert_not_contains "$tmp/fake-curl.log" "https://httpbin.org/anything"
assert_contains "$ROOT/tests/agent-modes.sh" 'AGENTS_MODES_LIVE_CLAUDE_FALLBACK_MODEL'
[ "$(grep -Fc -- '--fallback-model "$claude_fallback_model"' "$ROOT/tests/agent-modes.sh")" = "2" ] \
  || fail "Claude live runners do not share the fallback-model carrier"
python3 - "$tmp"/agents-*.config.toml "$tmp"/*.session.config.toml "$tmp/development.rendered.config.toml" "$ROOT/codex/tui.config.toml" <<'PY'
import pathlib
import sys

try:
    import tomllib
except ModuleNotFoundError:
    print("tomllib unavailable; skipping TOML parse", file=sys.stderr)
    raise SystemExit(0)

for name in sys.argv[1:]:
    tomllib.loads(pathlib.Path(name).read_text())
PY
python3 - "$tmp/development.rendered.config.toml" "$tmp/helpers/$run_as_user_executable" "$tmp/invocation.environment" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
try:
    import tomllib
except ModuleNotFoundError:
    assert f'command = "{sys.argv[2]}"' in text
    assert f'args = ["{sys.argv[3]}"]' in text
else:
    config = tomllib.loads(text)
    server = config["mcp_servers"]["run_as_user"]
    assert server["command"] == sys.argv[2]
    assert server["args"] == [sys.argv[3]]
    assert server["default_tools_approval_mode"] == "prompt"
    assert server["tools"]["run_as_user"]["approval_mode"] == "prompt"
PY
assert_success "$ROOT/tests/test-run-as-user.py"
python3 - "$ROOT/tests/mcp-probe" <<'PY'
import pathlib
import sys

compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec")
PY
python3 - "$ROOT/tests/process-group-exec.py" <<'PY'
import pathlib
import sys

compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec")
PY
python3 - "$ROOT/codex/helpers/codex-helper-dispatch" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
compile(source, sys.argv[1], "exec")
PY
assert_contains "$ROOT/codex/helpers/codex-launcher-dispatch.sh" '--workdir "$workdir"'
assert_contains "$ROOT/codex/helpers/codex-launcher-dispatch.sh" 'if [ "$#" -eq 0 ]; then'
assert_contains "$ROOT/codex/helpers/codex-helper-dispatch" 'working directory is outside the launched project'
for helper in \
  "$ROOT/container/runbox" \
  "$ROOT/helpers/sandbox-escape" \
  "$ROOT/modes/development/fetch-all" \
  "$ROOT/modes/development/ls-remote" \
  "$ROOT/modes/development/gh-ro"; do
  assert_contains "$helper" 'codex-dispatch-client.sh'
  case "$helper" in
    */gh-ro) assert_contains "$helper" 'codex_helper_path="${BASH_SOURCE[0]}"' ;;
    *) assert_contains "$helper" 'dirname "${BASH_SOURCE[0]}"' ;;
  esac
  assert_contains "$helper" 'codex_forward_helper_if_active "${BASH_SOURCE[0]##*/}" "$@"'
done
assert_contains "$ROOT/modes/development/gh-ro" 'exec "$ENV_BIN" -i'
assert_contains "$ROOT/modes/development/gh-ro" '#!/usr/bin/env -S BASH_ENV= ENV= /bin/bash'
assert_contains "$ROOT/modes/development/gh-ro" '"GH_HOST=github.com"'
assert_contains "$ROOT/modes/development/gh-ro" '"GH_CONFIG_DIR=$trusted_home/.config/gh"'
assert_contains "$ROOT/modes/development/gh-ro" 'gh_repo_env=("GH_REPO=github.com/$explicit_repo")'
assert_contains "$ROOT/modes/development/gh-ro" 'cd /'

note "checking Codex launcher sandbox activation"
launcher="$ROOT/codex/bin/codex-mode"
assert_not_contains "$launcher" '--enable exec_permission_approvals'
assert_not_contains "$launcher" 'approval_policy="$(awk'
assert_not_contains "$launcher" '--ask-for-approval'
assert_not_contains "$launcher" 'approval_config='
assert_not_contains "$launcher" 'exec -c "$approval_config" "$@"'
assert_contains "$launcher" 'codex-launcher-dispatch.sh'
assert_contains "$launcher" 'codex-launcher-session.sh'
assert_contains "$launcher" 'codex_validate_mode_args "$@"'
assert_contains "$launcher" 'codex_diagnose_sandbox'
assert_contains "$launcher" 'codex_start_mode_session'
assert_contains "$launcher" 'codex_start_helper_dispatch'
assert_not_contains "$launcher" '--strict-config'
assert_contains "$launcher" '--add-dir "$codex_dispatch_dir"'
assert_contains "$launcher" 'appended_toml="$(codex_toml_string "$appended")"'
assert_contains "$launcher" '--config "developer_instructions=$appended_toml"'
assert_contains "$launcher" 'codex --add-dir "$codex_dispatch_dir" --profile "$profile" "${codex_mode_config_args[@]}" --config "developer_instructions=$appended_toml" debug "$@"'
python3 - "$launcher" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
session = text.index("codex_start_mode_session \\\n")
box = text.index("  box_start\n", session)
dispatch = text.index('codex_start_helper_dispatch "$mode" "$helper_dir"', session)
assert session < box < dispatch
PY
assert_contains "$ROOT/codex/helpers/codex-launcher-session.sh" '/usr/bin/env -0 > "$environment_snapshot"'
assert_contains "$ROOT/codex/helpers/codex-launcher-session.sh" 'export CODEX_SQLITE_HOME="$codex_session_home"'
assert_contains "$ROOT/codex/helpers/codex-launcher-session.sh" 'codex_mode_config_args+=(--config "$override")'
assert_contains "$ROOT/codex/helpers/codex-launcher-session.sh" 'case=%s result=fail status=%s detail=%s'
assert_contains "$ROOT/tests/agent-modes.sh" 'default_tools_approval_mode = "approve"'
assert_not_contains "$ROOT/tests/agent-modes.sh" 'default_tools_approval_mode = "auto"'
assert_contains "$launcher" '.needs_container'
assert_not_contains "$launcher" "developer_instructions='''"
python3 "$ROOT/tools/agents-modes-gen" prompt codex development > "$tmp/development.prompt.md"
assert_contains "$tmp/development.prompt.md" 'call the run_as_user MCP tool exactly once'
assert_not_contains "$tmp/development.prompt.md" 'sandbox_permissions="with_additional_permissions"'
assert_not_contains "$tmp/development.prompt.md" 'rm -f /tmp'
assert_not_contains "$tmp/development.prompt.md" 'rm -f /private/tmp'

note "checking reviewed CLI versions"
if command -v claude >/dev/null 2>&1; then
  expected_claude="$(jq -r '.compatibility.claude.last_verified' "$ROOT/modes.json")"
  actual_claude="$(claude --version | awk '{print $1}')"
  note "Claude Code installed=$actual_claude last-verified=$expected_claude"
  if [ "$actual_claude" != "$expected_claude" ]; then
    note "compatibility notice: Claude Code differs from the last behaviorally verified version"
  fi
else
  note "claude not on PATH; skipping Claude compatibility notice"
fi
if command -v codex >/dev/null 2>&1; then
  expected_codex="$(jq -r '.compatibility.codex.last_verified' "$ROOT/modes.json")"
  actual_codex="$(codex --version | awk '{print $NF}')"
  note "Codex CLI installed=$actual_codex last-verified=$expected_codex"
  if [ "$actual_codex" != "$expected_codex" ]; then
    note "compatibility notice: Codex CLI differs from the last behaviorally verified version"
  fi
else
  note "codex not on PATH; skipping Codex compatibility notice"
fi

note "checking Makefile dry runs"
make -C "$ROOT" -n claude >/dev/null
make -C "$ROOT" -n codex >/dev/null
make -C "$ROOT" -n test-live >/dev/null
make -C "$ROOT" -n test-approvals >/dev/null
make -C "$ROOT" -n uninstall-codex >/dev/null
make -C "$ROOT" -n uninstall-shared-runtime >/dev/null
assert_contains "$ROOT/Makefile" 'MODES := $(shell $(GEN) mode-list)'
assert_contains "$ROOT/Makefile" 'RUNTIME_HELPER_SOURCES := $(shell $(GEN) runtime-helper-list)'
assert_contains "$ROOT/Makefile" 'CODEX_RUN_AS_USER_SOURCE := $(shell $(GEN) codex-run-as-user-source)'
assert_contains "$ROOT/Makefile" 'CLAUDE_LAUNCHER_SOURCE := claude/bin/claude-mode'
assert_contains "$ROOT/Makefile" 'CODEX_LAUNCHER_SOURCE := codex/bin/codex-mode'
assert_not_contains "$ROOT/Makefile" 'GIT_HELPERS'
