#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require_cmd jq
require_cmd make
require_cmd python3

prefix="$(tmp_dir install)"
prefix="$(cd "$prefix" && pwd -P)"
bindir="$prefix/bin"
share="$prefix/share"
claude_share="$prefix/claude"
codex_home="$prefix/codex"
codex_profiles="$share/codex/profiles"
codex_configs="$share/codex/config"
codex_rules="$share/codex/rules"
container_share="$share/container"
modes="$(python3 "$ROOT/tools/agents-modes-gen" mode-list)"
run_as_user_server="$(jq -r '.targets.codex.run_as_user.server' "$ROOT/modes.json")"
run_as_user_tool="$(jq -r '.targets.codex.run_as_user.tool' "$ROOT/modes.json")"

note "installing Claude and Codex into a temp prefix"
make -C "$ROOT" claude BINDIR="$bindir" CLAUDE_SHAREDIR="$claude_share" AGENTS_SHAREDIR="$share" CONTAINER_SHAREDIR="$container_share" >/dev/null
make -C "$ROOT" codex BINDIR="$bindir" CODEXHOME="$codex_home" AGENTS_SHAREDIR="$share" CONTAINER_SHAREDIR="$container_share" >/dev/null

pristine="$prefix/pristine"
mkdir -p "$pristine"
cp "$codex_profiles"/agents-*.config.toml "$pristine/"

for file in $(jq -r '(.helpers | keys[]), .targets.codex.run_as_user.executable' "$ROOT/modes.json") claude-launcher-settings.sh codex-helper-dispatch codex-launcher-dispatch.sh codex-launcher-session.sh codex-dispatch-client.sh; do
  assert_executable "$bindir/$file"
done
for mode in $modes; do
  assert_executable "$bindir/claude-$mode"
  assert_executable "$bindir/codex-$mode"
  cmp -s "$ROOT/claude/bin/claude-mode" "$bindir/claude-$mode" || fail "claude-$mode was not installed from the generic launcher"
  cmp -s "$ROOT/codex/bin/codex-mode" "$bindir/codex-$mode" || fail "codex-$mode was not installed from the generic launcher"
done

while IFS=$'\t' read -r helper source; do
  cmp -s "$ROOT/$source" "$bindir/$helper" || fail "installed $helper differs from $source"
done < <(jq -r '.helpers | to_entries[] | [.key, .value.source] | @tsv' "$ROOT/modes.json")
cmp -s "$ROOT/claude/helpers/claude-launcher-settings.sh" "$bindir/claude-launcher-settings.sh" || fail "installed claude-launcher-settings.sh differs from source"
cmp -s "$ROOT/codex/helpers/codex-helper-dispatch" "$bindir/codex-helper-dispatch" || fail "installed codex-helper-dispatch differs from source"
cmp -s "$ROOT/codex/helpers/codex-launcher-dispatch.sh" "$bindir/codex-launcher-dispatch.sh" || fail "installed codex-launcher-dispatch.sh differs from source"
cmp -s "$ROOT/codex/helpers/codex-launcher-session.sh" "$bindir/codex-launcher-session.sh" || fail "installed codex-launcher-session.sh differs from source"
cmp -s "$ROOT/codex/helpers/codex-dispatch-client.sh" "$bindir/codex-dispatch-client.sh" || fail "installed codex-dispatch-client.sh differs from source"
run_as_user_source="$(jq -r '.targets.codex.run_as_user.source' "$ROOT/modes.json")"
run_as_user_executable="$(jq -r '.targets.codex.run_as_user.executable' "$ROOT/modes.json")"
cmp -s "$ROOT/$run_as_user_source" "$bindir/$run_as_user_executable" || fail "installed $run_as_user_executable differs from source"
cmp -s "$ROOT/container/boxlib.sh" "$container_share/boxlib.sh" || fail "installed boxlib differs from source"
assert_file "$container_share/policy.sh"
assert_contains "$container_share/policy.sh" 'AGENTS_BOX_SECRET_GLOBS=('
assert_contains "$container_share/policy.sh" 'AGENTS_BOX_FORBIDDEN_PROJECT_PATHS=('

# What the settings CONTAIN is test-table.sh's job, against modes.json. This file checks
# that an install puts the right files in the right places, intact.
note "checking every mode has a generated settings file"
for mode in $modes; do
  assert_file "$claude_share/$mode.json"
  assert_file "$claude_share/$mode.mcp.json"
  jq empty "$claude_share/$mode.json" || fail "installed $mode.json is not valid JSON"
  jq empty "$claude_share/$mode.mcp.json" || fail "installed $mode.mcp.json is not valid JSON"
done

note "checking project-absolute Claude sandbox guards"
claude_project="$(tmp_dir claude-project-root)"
claude_project="$(cd "$claude_project" && pwd -P)"
rendered_settings="$(
  cd "$claude_project"
  # shellcheck source=/dev/null
  . "$bindir/claude-launcher-settings.sh"
  claude_prepare_session_settings "$claude_share/research.json" rendered "$claude_share" "$share" "$bindir"
  printf '%s' "$rendered"
)"
printf '%s' "$rendered_settings" | jq -e \
  --arg root "$claude_project" \
  --arg settings "$claude_share" \
  --arg agents "$share" \
  --arg helpers "$bindir" '
  [.sandbox.filesystem.denyWrite[] | select(startswith("./"))] == []
  and ([.sandbox.filesystem.denyWrite[] | select(startswith($root + "/"))] | length) > 0
  and ([.sandbox.filesystem.denyWrite[]] | index($settings) and index($settings + "/**"))
  and ([.sandbox.filesystem.denyWrite[]] | index($agents) and index($agents + "/**"))
  and ([.sandbox.filesystem.denyWrite[]] | index($helpers) and index($helpers + "/**"))
  and ([.permissions.ask[]] | index("Edit(/" + $settings + "/**)"))
  and ([.permissions.ask[]] | index("Edit(/" + $agents + "/**)"))
  and ([.permissions.ask[]] | index("Edit(/" + $helpers + "/**)"))
' >/dev/null || fail "session settings still carry ./-relative denyWrite guards, which bind to nothing"
for mode in $modes; do
  launcher="claude-$mode"
  assert_contains "$bindir/$launcher" 'claude-launcher-settings.sh'
  assert_contains "$bindir/$launcher" 'claude_validate_mode_args "$@"'
  assert_not_contains "$bindir/$launcher" "--setting-sources ''"
  assert_contains "$bindir/$launcher" '--settings "$session_settings"'
  assert_contains "$bindir/$launcher" '--strict-mcp-config'
  assert_contains "$bindir/$launcher" '--no-chrome'
done

note "checking Codex approval carriers"
assert_file "$codex_rules/agents-modes.rules"
assert_contains "$codex_rules/agents-modes.rules" 'pattern = ["runbox"]'
for mode in $modes; do
  profile="$codex_profiles/agents-$mode.config.toml"
  config="$codex_configs/$mode.config.toml"
  prompt="$share/prompts/codex/$mode.prompt.md"
  assert_contains "$prompt" 'call the run_as_user MCP tool exactly once'
  assert_not_contains "$prompt" 'sandbox_permissions="with_additional_permissions"'
  assert_contains "$config" 'exec_permission_approvals = false'
  assert_contains "$config" "[mcp_servers.$run_as_user_server]"
  assert_contains "$config" "command = \"$run_as_user_executable\""
  assert_contains "$config" 'args = ["__AGENTS_RUN_AS_USER_ENVIRONMENT__"]'
  assert_contains "$config" 'default_tools_approval_mode = "prompt"'
  assert_contains "$config" "[mcp_servers.$run_as_user_server.tools.$run_as_user_tool]"
  assert_contains "$config" 'approval_mode = "prompt"'
  if [ "$(jq -r --arg mode "$mode" '.modes[$mode].commands.sandboxed_auto' "$ROOT/modes.json")" = "true" ]; then
    assert_contains "$profile" 'approval_policy = "on-request"'
    assert_not_contains "$profile" 'approval_policy = "untrusted"'
  else
    assert_contains "$profile" 'approval_policy = "untrusted"'
    assert_not_contains "$profile" 'approval_policy = "on-request"'
  fi
  assert_not_contains "$profile" 'approval_policy = "never"'
  while IFS= read -r server; do
    [ -n "$server" ] || continue
    assert_contains "$config" "[mcp_servers.$server]"
  done < <(jq -r --arg mode "$mode" '.modes[$mode].mcp[]' "$ROOT/modes.json")

  launcher="codex-$mode"
  assert_not_contains "$bindir/$launcher" '--enable exec_permission_approvals'
  assert_not_contains "$bindir/$launcher" 'approval_policy="$(awk'
  assert_not_contains "$bindir/$launcher" '--ask-for-approval'
  assert_not_contains "$bindir/$launcher" 'approval_config='
  assert_not_contains "$bindir/$launcher" 'exec -c "$approval_config" "$@"'
  assert_contains "$bindir/$launcher" 'codex-launcher-dispatch.sh'
  assert_contains "$bindir/$launcher" 'codex-launcher-session.sh'
  assert_contains "$bindir/$launcher" 'codex_validate_mode_args "$@"'
  assert_contains "$bindir/$launcher" 'codex_diagnose_sandbox'
  assert_contains "$bindir/$launcher" 'codex_start_mode_session'
  assert_contains "$bindir/$launcher" 'codex_start_helper_dispatch'
  assert_not_contains "$bindir/$launcher" '--strict-config'
  assert_contains "$bindir/$launcher" '--add-dir "$codex_dispatch_dir"'
done

note "checking Codex helper dispatcher"
forward_dir="$(tmp_dir codex-dispatch-forward)"
cat > "$forward_dir/fetch-all" <<'SH'
#!/usr/bin/env bash
printf 'forwarded:%s\n' "${1:-}"
SH
chmod +x "$forward_dir/fetch-all"
assert_output_contains "forwarded:probe" env PATH="$bindir:$PATH" AGENTS_CODEX_MODE=development AGENTS_CODEX_DISPATCH_DIR="$forward_dir" fetch-all probe
shim_helpers="$(tmp_dir codex-dispatch-shim-helpers)"
cp "$bindir/codex-helper-dispatch" "$shim_helpers/codex-helper-dispatch"
cat > "$shim_helpers/fetch-all" <<'SH'
#!/usr/bin/env bash
printf 'argc=%s\n' "$#"
SH
chmod +x "$shim_helpers/fetch-all"
cat > "$shim_helpers/runbox" <<'SH'
#!/usr/bin/env bash
printf 'manifest-runbox:%s\n' "${1:-}"
SH
chmod +x "$shim_helpers/runbox"
# shellcheck source=/dev/null
. "$bindir/codex-launcher-dispatch.sh"
codex_start_helper_dispatch development "$shim_helpers" fetch-all
assert_output_contains "argc=0" "$codex_dispatch_dir/fetch-all"
codex_stop_helper_dispatch
AGENTS_MODES_DIR="$prefix/share" codex_start_helper_dispatch development "$shim_helpers"
assert_file "$codex_dispatch_dir/runbox"
manifest_reject="$(tmp_dir codex-dispatch-manifest-reject)"
if "$codex_dispatch_dir/runbox" true >"$manifest_reject/stdout" 2>"$manifest_reject/stderr"; then
  fail "development manifest shim allowed runbox"
fi
assert_contains "$manifest_reject/stderr" "helper not allowed in development: runbox"
codex_stop_helper_dispatch
AGENTS_MODES_DIR="$prefix/share" codex_start_helper_dispatch research "$shim_helpers"
assert_output_contains "manifest-runbox:probe" "$codex_dispatch_dir/runbox" probe
codex_stop_helper_dispatch
dispatch="$(tmp_dir codex-dispatch)"
fake_helpers="$(tmp_dir codex-dispatch-helpers)"
cat > "$fake_helpers/runbox" <<'SH'
#!/usr/bin/env bash
printf 'cwd=%s mode=%s host=%s args=%s/%s\n' "$PWD" "${AGENTS_CODEX_MODE:-}" "${AGENTS_CODEX_DISPATCH_HOST:-}" "${1:-}" "${2:-}"
SH
chmod +x "$fake_helpers/runbox"
"$bindir/codex-helper-dispatch" --dir "$dispatch" --mode research --helper-dir "$fake_helpers" --workdir "$ROOT" --helpers runbox &
dispatch_pid="$!"
request_seq=1000
new_request_base() {
  request_seq=$((request_seq + 1))
  request_base="$dispatch/request.$$.$request_seq.$request_seq"
}
wait_done() {
  local request="$1"
  for _ in $(seq 1 100); do
    [ -f "$request.done" ] && return 0
    sleep 0.05
  done
  return 1
}
malformed="$dispatch/request.malformed.1"
: > "$malformed.ready"
wait_done "$malformed" || fail "malformed request was not handled"
assert_file "$malformed.done"
assert_contains "$malformed.stderr" "codex-helper-dispatch: invalid request:"
assert_contains "$malformed.status" "2"
foreign="$(tmp_dir codex-dispatch-foreign)"
new_request_base
foreign_base="$request_base"
printf 'runbox' > "$foreign_base.helper"
printf '%s' "$foreign" > "$foreign_base.cwd"
: > "$foreign_base.args"
: > "$foreign_base.ready"
wait_done "$foreign_base" || fail "foreign request was not handled"
assert_file "$foreign_base.done"
assert_contains "$foreign_base.stderr" "working directory is outside the launched project"
assert_contains "$foreign_base.status" "2"
new_request_base
disallowed_base="$request_base"
printf 'sandbox-escape' > "$disallowed_base.helper"
printf '%s' "$ROOT" > "$disallowed_base.cwd"
: > "$disallowed_base.args"
: > "$disallowed_base.ready"
wait_done "$disallowed_base" || fail "disallowed request was not handled"
assert_file "$disallowed_base.done"
assert_contains "$disallowed_base.stderr" "helper not allowed in research: sandbox-escape"
assert_contains "$disallowed_base.status" "2"
read_secret_dir="$(tmp_dir codex-dispatch-read-symlink)"
printf 'TEMP_SECRET_MARKER\n' > "$read_secret_dir/secret"
new_request_base
read_symlink_base="$request_base"
ln -s "$read_secret_dir/secret" "$read_symlink_base.helper"
printf '%s' "$ROOT" > "$read_symlink_base.cwd"
: > "$read_symlink_base.args"
: > "$read_symlink_base.ready"
wait_done "$read_symlink_base" || fail "read-symlink request was not handled"
assert_file "$read_symlink_base.done"
assert_contains "$read_symlink_base.stderr" "codex-helper-dispatch: invalid request:"
assert_not_contains "$read_symlink_base.stderr" "TEMP_SECRET_MARKER"

write_symlink_dir="$(tmp_dir codex-dispatch-write-symlink)"
printf 'original\n' > "$write_symlink_dir/target"
new_request_base
write_symlink_base="$request_base"
ln -s "$write_symlink_dir/target" "$write_symlink_base.stderr"
printf 'sandbox-escape' > "$write_symlink_base.helper"
printf '%s' "$ROOT" > "$write_symlink_base.cwd"
: > "$write_symlink_base.args"
: > "$write_symlink_base.ready"
wait_done "$write_symlink_base" || fail "write-symlink request was not handled"
assert_equals "$(cat "$write_symlink_dir/target")" "original" "dispatcher must not write through stderr symlink"
[ ! -L "$write_symlink_base.stderr" ] || fail "dispatcher left stderr as a symlink"
assert_contains "$write_symlink_base.stderr" "helper not allowed in research: sandbox-escape"

new_request_base
base="$request_base"
printf 'runbox' > "$base.helper"
printf '%s' "$ROOT" > "$base.cwd"
printf 'alpha\0beta\0' > "$base.args"
: > "$base.ready"
wait_done "$base" || fail "valid request was not handled"
kill "$dispatch_pid" 2>/dev/null || true
wait "$dispatch_pid" 2>/dev/null || true
assert_file "$base.done"
assert_contains "$base.stdout" "cwd=$ROOT mode=research host=1 args=alpha/beta"
assert_contains "$base.status" "0"

if command -v codex >/dev/null 2>&1; then
  codex execpolicy check --pretty --rules "$codex_rules/agents-modes.rules" -- runbox true >"$prefix/execpolicy-runbox.json" \
    || fail "Codex execpolicy did not parse generated rules"
  jq -e '.decision == "allow"' "$prefix/execpolicy-runbox.json" >/dev/null \
    || fail "generated Codex rules do not allow runbox"
  codex execpolicy check --pretty --rules "$codex_rules/agents-modes.rules" -- sandbox-escape probe >"$prefix/execpolicy-sandbox-escape.json" \
    || fail "Codex execpolicy did not parse generated rules for sandbox-escape"
  jq -e '(.matchedRules | length) == 0 and has("decision") | not' "$prefix/execpolicy-sandbox-escape.json" >/dev/null \
    || fail "generated Codex rules unexpectedly match sandbox-escape"
fi

if command -v codex >/dev/null 2>&1; then
  note "checking Codex mode layers against hostile user and project config"
  hostile_project="$(tmp_dir hostile-codex-project)"
  auth_home="$(tmp_dir isolated-codex-auth)"
  git init -q "$hostile_project"
  mkdir -p "$hostile_project/.codex" "$codex_home"
  printf 'AUTH_HOME_INSTALLATION_ID\n' > "$auth_home/installation_id"
  printf 'AGENTS_MODES_PROJECT_INSTRUCTIONS_SURVIVE_ISOLATION\n' > "$hostile_project/AGENTS.md"
  cat > "$hostile_project/.codex/config.toml" <<'TOML'
sandbox_mode = "danger-full-access"

[mcp_servers.project_probe]
command = "/usr/bin/true"
enabled = true
TOML
  cat > "$codex_home/config.toml" <<'TOML'
model = "user-config-model"
model_provider = "user-config-provider"
sandbox_mode = "danger-full-access"

[model_providers.user-config-provider]
name = "User Config Provider"
base_url = "https://example.invalid/v1"
env_key = "USER_CONFIG_API_KEY"

[mcp_servers.user_probe]
command = "/usr/bin/true"
enabled = true
TOML
  for mode in $modes; do
    profile="agents-$mode"
    (
      cd "$hostile_project"
      export CODEX_HOME="$codex_home"
      export CODEX_SQLITE_HOME="$prefix/incoming-sqlite"
      export AGENTS_MODES_DIR="$share"
      export AGENTS_MODES_CODEX_AUTH_HOME="$auth_home"
      export AGENTS_RUN_AS_USER_INSTALL_PROBE="environment-preserved-$mode"
      # shellcheck source=/dev/null
      . "$bindir/codex-launcher-session.sh"
      codex_start_mode_session "$mode" "$profile" "$codex_profiles/$profile.config.toml" \
        "$codex_configs/$mode.config.toml" "$codex_rules/agents-modes.rules" "$bindir" \
        "$(jq -r '.targets.codex.run_as_user.executable' "$ROOT/modes.json")"
      assert_equals "$codex_session_state_home" "$codex_home" "$profile persistent session home"
      assert_equals "$CODEX_SQLITE_HOME" "$codex_session_home" "$profile isolated SQLite home"
      assert_equals "$(readlink "$codex_session_home/sessions")" "$codex_home/sessions" "$profile sessions link"
      assert_equals "$(readlink "$codex_session_home/archived_sessions")" "$codex_home/archived_sessions" "$profile archived sessions link"
      assert_equals "$(readlink "$codex_session_home/session_index.jsonl")" "$codex_home/session_index.jsonl" "$profile session index link"
      printf 'resume-state-%s\n' "$mode" > "$codex_session_home/sessions/$mode.resume-state"
      python3 - "$codex_session_mode_config_file" "$codex_session_home/run-as-user.environment" "$bindir/$run_as_user_executable" "$mode" <<'PY'
import pathlib
import sys

config_path, environment_path, executable, mode = sys.argv[1:]
text = pathlib.Path(config_path).read_text()
try:
    import tomllib
except ModuleNotFoundError:
    assert f'command = "{executable}"' in text
    assert f'args = ["{environment_path}"]' in text
else:
    config = tomllib.loads(text)
    server = config["mcp_servers"]["run_as_user"]
    assert server["command"] == executable
    assert server["args"] == [environment_path]
    assert server["default_tools_approval_mode"] == "prompt"
    assert server["tools"]["run_as_user"]["approval_mode"] == "prompt"
entries = pathlib.Path(environment_path).read_bytes().split(b"\0")
assert f"AGENTS_RUN_AS_USER_INSTALL_PROBE=environment-preserved-{mode}".encode() in entries
PY
      printf '%s\n' "$codex_session_home" > "$prefix/$profile.session-home"
      cp "$codex_session_profile_file" "$prefix/$profile.session-profile.toml"
      cp "$codex_session_config_file" "$prefix/$profile.session-config.toml"
      cp "$codex_session_mode_config_file" "$prefix/$profile.session-mode-config.toml"
      cp "$codex_session_home/installation_id" "$prefix/$profile.installation-id"
      codex --profile "$profile" debug prompt-input probe >"$prefix/$profile.json" 2>"$prefix/$profile.err"
      codex --profile "$profile" "${codex_mode_config_args[@]}" mcp list --json >"$prefix/$profile.mcp.json"
      codex_stop_mode_session
    ) || {
        sed -n '1,120p' "$prefix/$profile.err" >&2 || true
        fail "isolated Codex profile failed to load: $profile"
      }
    [ ! -e "$(cat "$prefix/$profile.session-home")" ] || fail "$profile left its isolated CODEX_HOME behind"
    assert_contains "$codex_home/sessions/$mode.resume-state" "resume-state-$mode"
    [ ! -e "$prefix/incoming-sqlite/state_5.sqlite" ] || fail "$profile wrote temporary index state to the incoming SQLite home"
    assert_not_contains "$prefix/$profile.json" 'danger-full-access'
    assert_contains "$prefix/$profile.session-config.toml" 'model = "user-config-model"'
    assert_contains "$prefix/$profile.session-config.toml" '[model_providers.user-config-provider]'
    assert_contains "$prefix/$profile.json" 'AGENTS_MODES_PROJECT_INSTRUCTIONS_SURVIVE_ISOLATION'
    assert_contains "$prefix/$profile.session-profile.toml" "\"$share\" = \"read\""
    assert_contains "$prefix/$profile.session-profile.toml" "\"$share/**\" = \"read\""
    assert_contains "$prefix/$profile.session-profile.toml" "\"$bindir\" = \"read\""
    assert_contains "$prefix/$profile.session-profile.toml" "\"$bindir/**\" = \"read\""
    assert_contains "$prefix/$profile.session-profile.toml" "\"$auth_home/auth.json\" = \"deny\""
    assert_contains "$prefix/$profile.installation-id" 'AUTH_HOME_INSTALLATION_ID'
    jq -e 'any(.[]; .name == "user_probe" and .enabled) and all(.[]; .name != "project_probe")' "$prefix/$profile.mcp.json" >/dev/null \
      || fail "$profile did not inherit only the user MCP server"
    for feature in apps browser_use browser_use_external browser_use_full_cdp_access computer_use hooks image_generation in_app_browser plugin_sharing plugins remote_plugin; do
      awk -v feature="$feature" '$1 == feature && $3 == "false" { found = 1 } END { exit !found }' "$prefix/$profile.session-mode-config.toml" \
        || fail "$profile left Codex feature enabled: $feature"
    done
    awk '$1 == "exec_permission_approvals" && $3 == "false" { found = 1 } END { exit !found }' "$prefix/$profile.session-mode-config.toml" \
      || fail "$profile did not disable exec_permission_approvals"
  done
  for mode in $modes; do
    profile="agents-$mode"
    expected_servers="$(jq -c --arg mode "$mode" '.modes[$mode].mcp + [.targets.codex.run_as_user.server, "user_probe"] | sort' "$ROOT/modes.json")"
    actual_servers="$(jq -c '[.[] | select(.enabled) | .name] | sort' "$prefix/$profile.mcp.json")"
    assert_equals "$actual_servers" "$expected_servers" "$profile isolated MCP config"
    if [ "$(jq -r --arg mode "$mode" '.modes[$mode].commands.sandboxed_auto' "$ROOT/modes.json")" = "true" ]; then
      assert_not_contains "$prefix/$profile.json" 'unless-trusted'
    else
      assert_contains "$prefix/$profile.json" 'unless-trusted'
      assert_contains "$prefix/$profile.json" 'Approvals are your mechanism to get user consent to run shell commands without the sandbox.'
    fi
  done
else
  note "codex not on PATH; skipping Codex profile-load checks"
fi

note "checking Codex default.rules cleanup preserves user rules"
preserve="$(tmp_dir preserve)"
preserve_bin="$preserve/bin"
preserve_share="$preserve/share"
preserve_home="$preserve/codex"
preserve_rules="$preserve_home/rules"
mkdir -p "$preserve_home" "$preserve_rules"
cat > "$preserve_home/default.rules" <<'RULES'
host_executable("echo", paths=["/bin/echo"])
prefix_rule(pattern=["echo"], decision="allow")
# BEGIN agents-modes managed rules
old managed block
# END agents-modes managed rules
host_executable("date", paths=["/bin/date"])
prefix_rule(pattern=["date"], decision="allow")
RULES
make -C "$ROOT" codex BINDIR="$preserve_bin" CODEXHOME="$preserve_home" AGENTS_SHAREDIR="$preserve_share" CONTAINER_SHAREDIR="$preserve_share/container" >/dev/null
assert_contains "$preserve_home/default.rules" '/bin/echo'
assert_contains "$preserve_home/default.rules" '/bin/date'
assert_not_contains "$preserve_home/default.rules" 'old managed block'
make -C "$ROOT" uninstall-codex BINDIR="$preserve_bin" CODEXHOME="$preserve_home" AGENTS_SHAREDIR="$preserve_share" CONTAINER_SHAREDIR="$preserve_share/container" >/dev/null
assert_contains "$preserve_home/default.rules" '/bin/echo'
assert_contains "$preserve_home/default.rules" '/bin/date'
assert_not_contains "$preserve_home/default.rules" 'BEGIN agents-modes managed rules'

note "checking legacy-only Codex rules removal"
clean="$(tmp_dir generated-only)"
make -C "$ROOT" codex BINDIR="$clean/bin" CODEXHOME="$clean/codex" AGENTS_SHAREDIR="$clean/share" CONTAINER_SHAREDIR="$clean/share/container" >/dev/null
make -C "$ROOT" uninstall-codex BINDIR="$clean/bin" CODEXHOME="$clean/codex" AGENTS_SHAREDIR="$clean/share" CONTAINER_SHAREDIR="$clean/share/container" >/dev/null
[ ! -e "$clean/codex/rules/agents-modes.rules" ] || fail "generated-only agents-modes.rules was not removed"
[ ! -e "$clean/codex/default.rules" ] || fail "generated-only default.rules was not removed"
[ ! -e "$clean/bin/codex-helper-dispatch" ] || fail "generated-only codex-helper-dispatch was not removed"
[ ! -e "$clean/bin/codex-launcher-dispatch.sh" ] || fail "generated-only codex-launcher-dispatch.sh was not removed"
[ ! -e "$clean/bin/codex-launcher-session.sh" ] || fail "generated-only codex-launcher-session.sh was not removed"
[ ! -e "$clean/bin/codex-dispatch-client.sh" ] || fail "generated-only codex-dispatch-client.sh was not removed"
[ ! -e "$clean/share/codex" ] || fail "generated-only isolated Codex templates were not removed"

note "checking generated-only Claude helper removal"
claude_clean="$(tmp_dir generated-only-claude)"
make -C "$ROOT" claude BINDIR="$claude_clean/bin" CLAUDE_SHAREDIR="$claude_clean/claude" AGENTS_SHAREDIR="$claude_clean/share" CONTAINER_SHAREDIR="$claude_clean/share/container" >/dev/null
make -C "$ROOT" uninstall-claude BINDIR="$claude_clean/bin" CLAUDE_SHAREDIR="$claude_clean/claude" AGENTS_SHAREDIR="$claude_clean/share" CONTAINER_SHAREDIR="$claude_clean/share/container" >/dev/null
[ ! -e "$claude_clean/bin/claude-launcher-settings.sh" ] || fail "generated-only claude-launcher-settings.sh was not removed"
