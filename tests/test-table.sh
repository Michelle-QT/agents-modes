#!/usr/bin/env bash
set -euo pipefail

# Asserts that the installed artifacts deliver the capability table in modes.json.
#
# Two rules keep this test honest as the repo changes underneath it:
#
# 1. It reads the INSTALLED artifacts in a temp prefix, never the authored sources.
#    The artifacts are generated from modes.json at install; this file asserted the same
#    things back when they were hand-authored, which is what made that refactor a refactor.
#
# 2. It is an independent reader, not the generator's mirror. It re-derives what each
#    cell implies and compares. A test that rendered from modes.json and diffed against
#    something generated from modes.json would pass vacuously.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require_cmd jq
require_cmd make
require_cmd python3

spec="$ROOT/modes.json"
assert_file "$spec"
jq empty "$spec" || fail "modes.json is not valid JSON"

prefix="$(tmp_dir table)"
bindir="$prefix/bin"
claude_share="$prefix/claude"
codex_home="$prefix/codex"
codex_profiles="$prefix/share/codex/profiles"
codex_configs="$prefix/share/codex/config"
codex_rules="$prefix/share/codex/rules/agents-modes.rules"
note "installing into a temp prefix to check the artifacts, not the sources"
make -C "$ROOT" claude BINDIR="$bindir" CLAUDE_SHAREDIR="$claude_share" \
  AGENTS_SHAREDIR="$prefix/share" CONTAINER_SHAREDIR="$prefix/share/container" >/dev/null
make -C "$ROOT" codex BINDIR="$bindir" CODEXHOME="$codex_home" \
  AGENTS_SHAREDIR="$prefix/share" CONTAINER_SHAREDIR="$prefix/share/container" >/dev/null

modes="$(jq -r '.modes | keys[]' "$spec")"
spec_get() { jq -r "$1" "$spec"; }
run_as_user_server="$(spec_get '.targets.codex.run_as_user.server')"
run_as_user_tool="$(spec_get '.targets.codex.run_as_user.tool')"
run_as_user_executable="$(spec_get '.targets.codex.run_as_user.executable')"

note "checking every mode in modes.json has an artifact on both targets"
for mode in $modes; do
  assert_file "$claude_share/$mode.json"
  assert_file "$claude_share/$mode.mcp.json"
  assert_file "$codex_profiles/agents-$mode.config.toml"
  assert_file "$codex_configs/$mode.config.toml"
  assert_file "$prefix/share/modes/$mode.json"
  assert_file "$prefix/share/prompts/claude/$mode.prompt.md"
  assert_file "$prefix/share/prompts/codex/$mode.prompt.md"
done

note "checking mode identities agree"
for mode in $modes; do
  slug="$(spec_get ".modes[\"$mode\"].slug")"
  display="$(spec_get ".modes[\"$mode\"].display")"
  assert_equals "$slug" "$mode" "modes.json key vs slug for $mode"
  assert_equals "$(printf '%s' "$display" | tr '[:upper:]' '[:lower:]')" "$slug" "display lowercased vs slug for $mode"
  assert_equals "$(jq -r '.env.AGENTS_CLAUDE_MODE' "$claude_share/$mode.json")" "$slug" "AGENTS_CLAUDE_MODE for $mode"
  jq -e '.env | has("CLAUDE_MODE") | not' "$claude_share/$mode.json" >/dev/null \
    || fail "$mode: generated Claude settings retain legacy CLAUDE_MODE"
  assert_equals "$(jq -r '.slug' "$prefix/share/modes/$mode.json")" "$slug" "manifest slug for $mode"
  expected_container="$(jq -r --arg mode "$mode" '[.modes[$mode].commands.grants[] as $helper | .helpers[$helper].needs_container // false] | any' "$spec")"
  assert_equals "$(jq -r '.needs_container' "$prefix/share/modes/$mode.json")" "$expected_container" "container lifecycle for $mode"
  assert_equals \
    "$(jq -r '.codex_run_as_user.executable' "$prefix/share/modes/$mode.json")" \
    "$(spec_get '.targets.codex.run_as_user.executable')" \
    "Codex run_as_user executable for $mode"
done

note "checking every axis on BOTH surfaces, for every mode"
# Every axis has two surfaces on Claude: the native one (permission rules, which govern
# the built-in tools) and the sandboxed one (sandbox.*, which governs Bash). A cell
# delivered on one surface and not the other is half a cell, and reads as a guard that
# does not exist. Every axis is checked on both, in every mode, driven from modes.json --
# hand-enumerating cases is what let the secrets row protect `cat` and not `Read`, and
# what let Research's read cell look done while its sandbox read the whole host.
for mode in $modes; do
  settings="$claude_share/$mode.json"
  profile="$codex_profiles/agents-$mode.config.toml"
  region="$(spec_get ".modes[\"$mode\"].read.region")"
  native_read="$(jq -r '[.permissions.allow[]? | select(. == "Read")] | length' "$settings")"
  sandbox_allow_read="$(jq -r '.sandbox.filesystem.allowRead // [] | length' "$settings")"
  sandbox_deny_home="$(jq -r '[.sandbox.filesystem.denyRead[]? | select(. == "~/")] | length' "$settings")"

  case "$region" in
    host)
      # native: a bare Read allow means never prompt, which is the whole host.
      assert_equals "$native_read" "1" "$mode: read/native (bare Read allow)"
      # sandboxed: deny-only, so the region is the host minus the denied paths.
      assert_equals "$sandbox_allow_read" "0" "$mode: read/sandboxed (no allowRead confinement)"
      assert_contains "$profile" '":root" = "read"'
      ;;
    workdir)
      # native: the ABSENCE of a bare Read allow is the confinement.
      assert_equals "$native_read" "0" "$mode: read/native (no bare Read allow)"
      # sandboxed: needs saying explicitly, or deny-only leaves it reading the host.
      assert_equals "$sandbox_allow_read" "1" "$mode: read/sandboxed (allowRead confines to the project)"
      assert_equals "$sandbox_deny_home" "1" "$mode: read/sandboxed (denyRead ~/ is what allowRead carves out of)"
      assert_contains "$profile" '":minimal" = "read"'
      ;;
    *) fail "$mode: unknown read region: $region" ;;
  esac

  # egress, both surfaces. The web tools are native egress exactly as Read is native
  # read; sandbox.network is the sandboxed leg.
  dest="$(spec_get ".modes[\"$mode\"].egress.destinations")"
  native_web="$(jq -r '[.permissions.allow[]? | select(. == "WebFetch")] | length' "$settings")"
  if [ "$dest" = "any" ]; then
    assert_equals "$native_web" "1" "$mode: egress/native (web tools reach any destination)"
    assert_contains "$profile" 'web_search = "live"'
  else
    assert_equals "$native_web" "0" "$mode: egress/native (no web tools)"
    assert_contains "$profile" 'web_search = "disabled"'
  fi

  # secrets, both surfaces. Read() deny rules are the native leg and merge into the
  # sandbox; denyRead is the sandbox's own second gate on the same home paths.
  for entry in $(spec_get '.secrets.home[].path'); do
    jq -e --arg r "Read($entry)" '[.permissions.deny[]? | select(. == $r)] | length == 1' "$settings" >/dev/null \
      || fail "$mode: secrets/native missing Read($entry)"
    jq -e --arg p "$entry" '[.sandbox.filesystem.denyRead[]? | select(. == $p)] | length == 1' "$settings" >/dev/null \
      || fail "$mode: secrets/sandboxed missing denyRead $entry"
  done

  # write, both surfaces. Edit() ask rules are the native leg; denyWrite is the sandbox's.
  for path in $(spec_get '.forbidden.groups[].paths[] | select(.scope=="project") | .path'); do
    tree="$(spec_get ".forbidden.groups[].paths[] | select(.path==\"$path\") | .kind")"
    target="./$path"; [ "$tree" = "tree" ] && target="./$path/**"
    jq -e --arg r "Edit($target)" '[.permissions.ask[]? | select(. == $r)] | length == 1' "$settings" >/dev/null \
      || fail "$mode: write/native missing Edit($target) for forbidden $path"
    jq -e --arg p "./$path" '[.sandbox.filesystem.denyWrite[]? | select(. == $p)] | length == 1' "$settings" >/dev/null \
      || fail "$mode: write/sandboxed missing denyWrite ./$path"
  done
  # Write() rules are never matched by file permission checks; only Edit() is.
  jq -e '[.permissions.ask[]?, .permissions.deny[]? | select(startswith("Write("))] | length == 0' "$settings" >/dev/null \
    || fail "$mode: emits a Write() rule, which Claude never matches (Edit covers all file-editing tools)"

  # write, allow side. The `plus` grant has two carriers on Claude (additionalDirectories
  # for the built-in tools, allowWrite for sandboxed Bash) and three keys on Codex; the
  # deny edge alone is half the cell.
  plus="$(spec_get ".modes[\"$mode\"].write.plus | length")"
  tmp_paths="$(spec_get '.targets.claude.tmp_paths | sort | join(",")')"
  if [ "$plus" != "0" ]; then
    assert_equals "$(jq -r '.permissions.additionalDirectories // [] | sort | join(",")' "$settings")" \
      "$tmp_paths" "$mode: write/native (additionalDirectories carries the /tmp grant)"
    assert_equals "$(jq -r '.sandbox.filesystem.allowWrite // [] | sort | join(",")' "$settings")" \
      "$tmp_paths" "$mode: write/sandboxed (allowWrite carries the /tmp grant)"
    assert_contains "$profile" '":tmpdir" = "write"'
    assert_contains "$profile" '":slash_tmp" = "write"'
    assert_contains "$profile" '"/private/tmp" = "write"'
  else
    jq -e '.permissions | has("additionalDirectories") | not' "$settings" >/dev/null \
      || fail "$mode: write/native grants /tmp the table does not give"
    jq -e '.sandbox.filesystem | has("allowWrite") | not' "$settings" >/dev/null \
      || fail "$mode: write/sandboxed grants /tmp the table does not give"
    assert_not_contains "$profile" '":tmpdir"'
    assert_not_contains "$profile" '":slash_tmp"'
  fi
  # The workspace itself: Codex says it explicitly; on Claude it is the sandbox default
  # plus acceptEdits, so there is no key to assert.
  assert_contains "$profile" '"." = "write"'
done

note "checking secrets: every path is denied to both surfaces, in every mode"
secret_rules="$(python3 - "$spec" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))["secrets"]
# A tree needs the bare rule and the recursive one; a file needs one.
for entry in s["home"]:
    print(f"Read({entry['path']})")
    if entry["kind"] == "tree":
        print(f"Read({entry['path']}/**)")
for g in s["in_tree"]:
    print(f"Read({g})")
PY
)"
for mode in $modes; do
  settings="$claude_share/$mode.json"
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    jq -e --arg r "$rule" '[.permissions.deny[]? | select(. == $r)] | length == 1' "$settings" >/dev/null \
      || fail "$mode: secrets rule missing from permissions.deny: $rule"
  done <<< "$secret_rules"
done

note "checking secrets: Codex denies home paths host-wide and in-tree patterns in-tree"
for mode in $modes; do
  profile="$codex_profiles/agents-$mode.config.toml"
  for path in $(spec_get '.secrets.home[].path'); do
    assert_contains "$profile" "\"$path\" = \"deny\""
  done
  for glob in $(spec_get '.secrets.in_tree[]'); do
    assert_contains "$profile" "\"${glob}\" = \"deny\""
    # NOT host-wide. A host-wide "/**/*.pem" denies /etc/ssl/cert.pem, the system CA
    # bundle, and breaks TLS for every sandboxed command. Found by the agent tier, where
    # curl failed with "error setting certificate verify locations"; pinned here so it
    # is caught for free next time.
    assert_not_contains "$profile" "\"/${glob}\" = \"deny\""
  done
done


note "checking forbidden: the escape surface and box definition are unwritable everywhere"
for mode in $modes; do
  jq -e '[.sandbox.filesystem.denyWrite[]?] | index("./sandbox-escapes") and index("./sandbox-escapes/**")' \
    "$claude_share/$mode.json" >/dev/null || fail "$mode: sandbox-escapes is not denyWrite"
  jq -e '[.sandbox.filesystem.denyWrite[]?] | index("./container") and index("./container/**")' \
    "$claude_share/$mode.json" >/dev/null || fail "$mode: container is not denyWrite"
  assert_contains "$codex_profiles/agents-$mode.config.toml" '"sandbox-escapes" = "read"'
  assert_contains "$codex_profiles/agents-$mode.config.toml" '"container" = "read"'
done

note "checking forbidden: .git stays writable, config and hooks do not"
for mode in $modes; do
  profile="$codex_profiles/agents-$mode.config.toml"
  if grep -Fq '".git/**" = "write"' "$profile"; then
    assert_contains "$profile" '".git/config" = "read"'
    assert_contains "$profile" '".git/hooks/**" = "read"'
  fi
done

note "checking forbidden: home-scoped paths are denyWrite on Claude and absent on Codex"
# On Codex the workspace is the only writable region, so a home path is already
# unwritable and any entry would be wrong ("deny" contradicts readable, "read" would
# widen Research). On Claude denyWrite is the belt on top of the same region confinement.
for mode in $modes; do
  settings="$claude_share/$mode.json"
  profile="$codex_profiles/agents-$mode.config.toml"
  while IFS=$'\t' read -r path kind; do
    [ -n "$path" ] || continue
    jq -e --arg p "$path" '[.sandbox.filesystem.denyWrite[]?] | index($p)' "$settings" >/dev/null \
      || fail "$mode: home forbidden $path is not denyWrite"
    if [ "$kind" = "tree" ]; then
      jq -e --arg p "$path/**" '[.sandbox.filesystem.denyWrite[]?] | index($p)' "$settings" >/dev/null \
        || fail "$mode: home forbidden $path/** is not denyWrite"
    fi
    assert_not_contains "$profile" "\"$path\""
  done < <(jq -r '.forbidden.groups[].paths[] | select(.scope=="home") | [.path, .kind] | @tsv' "$spec")
done

note "checking mcp: isolated configs name exactly each mode's servers plus the Codex command carrier"
for mode in $modes; do
  settings="$claude_share/$mode.json"
  claude_mcp="$claude_share/$mode.mcp.json"
  codex_config="$codex_configs/$mode.config.toml"
  want="$(spec_get ".modes[\"$mode\"].mcp | length")"
  got="$(jq -r '[.permissions.allow[]? | select(startswith("mcp__"))] | length' "$settings")"
  assert_equals "$got" "$want" "$mode: mcp allow rules"
  assert_equals "$(jq -r '.mcpServers | length' "$claude_mcp")" "$want" "$mode: Claude MCP config"
  assert_contains "$codex_config" "[mcp_servers.$run_as_user_server]"
  assert_contains "$codex_config" "command = \"$run_as_user_executable\""
  assert_contains "$codex_config" 'args = ["__AGENTS_RUN_AS_USER_ENVIRONMENT__"]'
  assert_contains "$codex_config" 'default_tools_approval_mode = "prompt"'
  assert_contains "$codex_config" "[mcp_servers.$run_as_user_server.tools.$run_as_user_tool]"
  assert_contains "$codex_config" 'approval_mode = "prompt"'
  for server in $(spec_get ".modes[\"$mode\"].mcp[]"); do
    jq -e --arg r "mcp__${server}__*" '[.permissions.allow[]? | select(. == $r)] | length == 1' "$settings" >/dev/null \
      || fail "$mode: mcp grants $server but no mcp__${server}__* allow rule"
    jq -e --arg server "$server" '.mcpServers | has($server)' "$claude_mcp" >/dev/null \
      || fail "$mode: Claude MCP config misses $server"
    assert_contains "$codex_config" "[mcp_servers.$server]"
    assert_contains "$codex_config" 'default_tools_approval_mode = "approve"'
  done
done

note "checking integrations: Codex mode overrides close known native integration surfaces"
for mode in $modes; do
  config="$codex_configs/$mode.config.toml"
  assert_contains "$config" '[apps._default]'
  assert_contains "$config" 'open_world_enabled = false'
  assert_contains "$config" 'apps = false'
  assert_contains "$config" 'browser_use = false'
  assert_contains "$config" 'browser_use_external = false'
  assert_contains "$config" 'computer_use = false'
  assert_contains "$config" 'hooks = false'
  assert_contains "$config" 'image_generation = false'
  assert_contains "$config" 'in_app_browser = false'
  assert_contains "$config" 'plugin_sharing = false'
  assert_contains "$config" 'plugins = false'
  assert_contains "$config" 'remote_plugin = false'
done

note "checking commands: grants match excludedCommands, as a bare and a glob token each"
for mode in $modes; do
  want="$(spec_get ".modes[\"$mode\"].commands.grants | map(., . + \" *\") | sort | join(\",\")")"
  got="$(jq -r '[.sandbox.excludedCommands[]?] | sort | join(",")' "$claude_share/$mode.json")"
  assert_equals "$got" "$want" "$mode: excludedCommands vs commands.grants"
done

note "checking commands: sandboxed auto is carried by the bare Bash allow and the sandbox flag"
for mode in $modes; do
  settings="$claude_share/$mode.json"
  auto="$(spec_get ".modes[\"$mode\"].commands.sandboxed_auto")"
  has_bash="$(jq -r '[.permissions.allow[]? | select(. == "Bash")] | length' "$settings")"
  flag="$(jq -r '.sandbox.autoAllowBashIfSandboxed' "$settings")"
  assert_equals "$flag" "$auto" "$mode: autoAllowBashIfSandboxed"
  if [ "$auto" = "true" ]; then
    [ "$has_bash" = "1" ] || fail "$mode: sandboxed auto needs a bare Bash allow, or even a sandboxed loop prompts"
  else
    [ "$has_bash" = "0" ] || fail "$mode: a bare Bash allow contradicts sandboxed_auto false"
  fi
done

note "checking commands: the only route out of the sandbox always prompts"
for mode in $modes; do
  jq -e '[.permissions.ask[]?] | index("Bash(dangerouslyDisableSandbox:true)")' "$claude_share/$mode.json" >/dev/null \
    || fail "$mode: dangerouslyDisableSandbox is not gated"
done

note "checking commands: Codex approval policy uses prompt-capable carriers"
assert_file "$codex_rules"
boxed_no_auto="$(
  jq -r '. as $s
    | .modes[]
    | select(.commands.sandboxed_auto == false)
    | .commands.grants[]
    | select($s.helpers[.].needs_container == true)' "$spec"
)"
for mode in $modes; do
  profile="$codex_profiles/agents-$mode.config.toml"
  auto="$(spec_get ".modes[\"$mode\"].commands.sandboxed_auto")"
  if [ "$auto" = "true" ]; then
    assert_contains "$profile" 'approval_policy = "on-request"'
    assert_not_contains "$profile" 'approval_policy = "untrusted"'
  else
    assert_contains "$profile" 'approval_policy = "untrusted"'
    assert_not_contains "$profile" 'approval_policy = "on-request"'
  fi
done
for mode in $modes; do
  assert_contains "$codex_configs/$mode.config.toml" 'exec_permission_approvals = false'
  assert_contains "$prefix/share/prompts/codex/$mode.prompt.md" 'call the run_as_user MCP tool exactly once'
  assert_not_contains "$prefix/share/prompts/codex/$mode.prompt.md" 'sandbox_permissions="with_additional_permissions"'
done
for helper in $(jq -r '.helpers | keys[]' "$spec"); do
  if printf '%s\n' "$boxed_no_auto" | grep -Fxq "$helper"; then
    assert_contains "$codex_rules" "pattern = [\"$helper\"]"
  else
    assert_not_contains "$codex_rules" "pattern = [\"$helper\"]"
  fi
done

note "checking the coverage matrix spans every mode, axis, and target"
behavior_matrix="$prefix/behavior-matrix.json"
approval_witness_matrix="$prefix/approval-witness-matrix.json"
python3 "$ROOT/tools/agents-modes-gen" behavior-matrix-json --output "$behavior_matrix"
python3 "$ROOT/tools/agents-modes-gen" approval-witness-matrix-json --output "$approval_witness_matrix"
jq empty "$behavior_matrix" || fail "generated coverage matrix is not valid JSON"
jq empty "$approval_witness_matrix" || fail "generated approval witness matrix is not valid JSON"
for target in claude codex; do
  for mode in $modes; do
    for axis in read write egress secrets forbidden mcp integrations commands; do
      jq -e --arg target "$target" --arg mode "$mode" --arg axis "$axis" '
        any(.[]; .target == $target and .mode == $mode and .axis == $axis)
      ' "$behavior_matrix" >/dev/null \
        || fail "$target-$mode: no coverage row for axis $axis"
    done
    auto="$(spec_get ".modes[\"$mode\"].commands.sandboxed_auto")"
    if [ "$auto" = "true" ]; then
      case_name="outside-write"
    else
      case_name="host-shell"
    fi
    jq -e --arg target "$target" --arg mode "$mode" '
      any(.[]; .target == $target and .mode == $mode and .case == "positive" and .outcome == "runs")
    ' "$behavior_matrix" >/dev/null \
      || fail "$target-$mode: coverage matrix misses positive/runs"
    jq -e --arg target "$target" --arg mode "$mode" --arg case "$case_name" '
      any(.[]; .target == $target and .mode == $mode and .case == $case and .outcome == "blocked-or-prompted")
    ' "$behavior_matrix" >/dev/null \
      || fail "$target-$mode: coverage matrix misses $case_name/blocked-or-prompted"
    # The witness is per carrier, so a mode is covered when a representative's row lists
    # it, not when it has a row of its own.
    for check in prompt-appears deny-prevents-execution accept-runs-as-user; do
      jq -e --arg target "$target" --arg mode "$mode" --arg check "$check" '
        [.[] | select(.target == $target and .check == $check and .runner == "manual"
                      and (.covers | index($mode)))] | length == 1
      ' "$approval_witness_matrix" >/dev/null \
        || fail "$target-$mode: approval witness matrix does not cover $check exactly once"
    done
  done
done
jq -e '
  all(.[]; .outcome == "runs" or .outcome == "blocked-or-prompted" or .outcome == "asserted" or .outcome == "gap")
  and all(.[]; (.outcome == "prompt_deny" or .outcome == "prompt_accept") | not)
' "$behavior_matrix" >/dev/null || fail "coverage matrix overclaims approval outcomes"
while IFS=$'\t' read -r target mode axis; do
  [ -n "$target" ] || continue
  jq -e --arg target "$target" --arg mode "$mode" --arg axis "$axis" '
    any(.[]; .target == $target and .mode == $mode and .axis == $axis and .outcome == "gap")
  ' "$behavior_matrix" >/dev/null \
    || fail "$target-$mode: coverage matrix misses target gap for $axis"
done < <(jq -r '.targets | to_entries[] | .key as $target | .value.gaps[]? | .axis as $axis | .modes[] | [$target, ., $axis] | @tsv' "$spec")
while IFS=$'\t' read -r target mode axis; do
  [ -n "$target" ] || continue
  jq -e --arg target "$target" --arg mode "$mode" --arg axis "$axis" '
    any(.[]; .target == $target and .mode == $mode and .axis == $axis
        and .behavior == "accepted-gap" and .outcome == "gap")
  ' "$behavior_matrix" >/dev/null \
    || fail "$target-$mode: coverage matrix misses accepted gap for $axis"
done < <(jq -r '.gaps[]? | .axis as $axis | .modes[] as $mode | .targets[] | [., $mode, $axis] | @tsv' "$spec")
jq -e '
  any(.[]; .target == "codex" and .mode == "research" and .case == "host-shell" and .check == "prompt-appears")
  and any(.[]; .target == "codex" and .mode == "research" and .case == "host-shell" and .check == "deny-prevents-execution")
  and any(.[]; .target == "codex" and .mode == "research" and .case == "host-shell" and .check == "accept-runs-as-user")
' "$approval_witness_matrix" >/dev/null || fail "approval witness matrix misses Codex Research host-shell"

note "checking every container coverage row has a matching case in live-docker.sh"
# The container tier is one hand-written flow, so the cross-check is a token: a row with
# runner=container must name a case that live-docker.sh carries as a `# case:` marker.
while IFS= read -r case_name; do
  [ -n "$case_name" ] || continue
  grep -Fq "case: $case_name" "$ROOT/tests/live-docker.sh" \
    || fail "live-docker.sh does not carry container case: $case_name"
done < <(jq -r '[.[] | select(.runner == "container") | .case] | unique[]' "$behavior_matrix")

note "checking declared Codex target gaps are complete and emitted generically"
jq -e '
  (.targets.codex.gaps // []) as $gaps
  | all($gaps[]; (.axis | length > 0) and (.modes | length > 0) and (.desired | length > 0) and (.actual | length > 0) and (.status | length > 0))
' "$spec" >/dev/null || fail "Codex target gaps are incomplete"
for mode in $modes; do
  profile="$codex_profiles/agents-$mode.config.toml"
  expected_gaps="$(spec_get "[.targets.codex.gaps[]? | select(.modes | index(\"$mode\"))] | length")"
  actual_gaps="$(grep -c '^# Target gap (' "$profile" || true)"
  assert_equals "$actual_gaps" "$expected_gaps" "$mode: emitted target-gap comments"
  while IFS= read -r axis; do
    [ -n "$axis" ] || continue
    assert_contains "$profile" "Target gap ($axis):"
  done < <(jq -r --arg mode "$mode" '.targets.codex.gaps[]? | select(.modes | index($mode)) | .axis' "$spec")
done

note "checking commands: Codex manifests shim every globally approved helper"
for mode in $modes; do
  manifest="$prefix/share/modes/$mode.json"
  for helper in $(jq -r '.helpers | keys[]' "$spec"); do
    if jq -e --arg h "$helper" '.modes["'"$mode"'"].commands.grants | index($h)' "$spec" >/dev/null \
      || printf '%s\n' "$boxed_no_auto" | grep -Fxq "$helper"; then
      jq -e --arg h "$helper" '.shims | index($h)' "$manifest" >/dev/null \
        || fail "$mode: Codex manifest does not shim $helper"
    else
      jq -e --arg h "$helper" '.shims | index($h) | not' "$manifest" >/dev/null \
        || fail "$mode: Codex manifest shims unneeded helper $helper"
    fi
  done
done

note "checking egress: destinations match, and the sandbox opens only where it serves something"
for mode in $modes; do
  settings="$claude_share/$mode.json"
  profile="$codex_profiles/agents-$mode.config.toml"
  dest="$(spec_get ".modes[\"$mode\"].egress.destinations")"
  auto="$(spec_get ".modes[\"$mode\"].commands.sandboxed_auto")"
  domains="$(jq -r '.sandbox.network.allowedDomains // [] | join(",")' "$settings")"
  # `*` means one thing everywhere: any destination is reachable. Whether the mode's own
  # sandbox carries that egress is derived, not declared: the sandbox network exists to
  # serve sandboxed host commands, so it stays shut in a mode that auto-runs none.
  case "$dest" in
    any)
      if [ "$auto" = "true" ]; then
        assert_equals "$domains" "*" "$mode: unrestricted egress with sandboxed auto opens the sandbox"
        assert_contains "$profile" "enabled = true"
      else
        assert_equals "$domains" "" "$mode: no sandboxed auto, so the sandbox network serves nothing and stays shut"
        assert_contains "$profile" "enabled = false"
      fi
      # WebFetch/WebSearch are generated exactly where destinations == any, so native
      # egress is the reachability witness; Research also reaches the network through runbox.
      ;;
    named)
      assert_equals "$domains" "" "$mode: named egress must not open the sandbox"
      assert_contains "$profile" "enabled = false"
      for helper in $(spec_get ".modes[\"$mode\"].egress.via[]"); do
        jq -e --arg h "$helper" '[.sandbox.excludedCommands[]?] | index($h)' "$settings" >/dev/null \
          || fail "$mode: egress names $helper but no excludedCommands token grants it"
      done
      ;;
    none)
      assert_equals "$domains" "" "$mode: egress is off"
      assert_contains "$profile" "enabled = false"
      for helper in $(spec_get ".modes[\"$mode\"].commands.grants[]"); do
        [ "$(spec_get ".helpers[\"$helper\"].grants_egress")" != "true" ] \
          || fail "$mode: egress is off but it grants $helper, which reaches the network"
      done
      ;;
    *) fail "$mode: unknown egress destinations: $dest" ;;
  esac
done

note "checking the README generated blocks render modes.json"
# Generate and diff, rather than parse: parsing markdown means writing a second, buggier
# renderer and comparing two lossy projections. The diff's output is the patch.
#
# Whitespace inside cells is normalized because README's table is pipe-aligned by a
# formatter; the check is about content, not column widths. Both sides are guarded
# against being empty, so a missing block cannot pass by comparing nothing to nothing --
# which is the shape of every silent pass this suite has had.
readme_dir="$(tmp_dir readme)"
python3 - "$ROOT/README.md" "$spec" <<'PY'
import json
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
begin = "<!-- agents-modes:begin table -->"
end = "<!-- agents-modes:end table -->"
assert begin + "\n\n|" in text, "README table needs a blank line after its begin marker"
assert "|\n\n" + end in text, "README table needs a blank line before its end marker"
begin = "<!-- agents-modes:begin gaps -->"
end = "<!-- agents-modes:end gaps -->"
assert begin + "\n\n-" in text, "README gaps need a blank line after their begin marker"
assert ".\n\n" + end in text, "README gaps need a blank line before their end marker"

spec = json.loads(pathlib.Path(sys.argv[2]).read_text())
gaps = list(spec.get("gaps", []))
for target in spec["targets"].values():
    gaps.extend(target.get("gaps", []))
for gap in gaps:
    for field in ("desired", "actual", "status"):
        value = gap[field]
        assert text.count(value) == 1, f"README must render gap {field} exactly once: {value}"
PY
# Collapse inner whitespace, and collapse a markdown separator row's dashes: a formatter
# pads both to align the columns, and neither carries meaning.
norm() {
  sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/ *| */|/g' -e 's/^ *//' -e 's/ *$//' \
      -e '/^|[-|]*$/s/--*/---/g' "$1"
}
for block in table secrets forbidden integrations gaps; do
  python3 "$ROOT/tools/agents-modes-gen" readme-block "$block" > "$readme_dir/$block.expected" \
    || fail "generator failed for readme-block $block"
  python3 "$ROOT/tools/agents-modes-gen" readme-extract "$block" "$ROOT/README.md" > "$readme_dir/$block.actual" \
    || fail "README has no markers for block: $block"
  [ -s "$readme_dir/$block.expected" ] || fail "rendered README block is empty: $block"
  [ -s "$readme_dir/$block.actual" ] || fail "extracted README block is empty: $block"
  norm "$readme_dir/$block.actual" > "$readme_dir/$block.actual.norm"
  norm "$readme_dir/$block.expected" > "$readme_dir/$block.expected.norm"
  diff -u "$readme_dir/$block.actual.norm" "$readme_dir/$block.expected.norm" \
    || fail "README block '$block' does not match modes.json (the diff above is the patch)"
done

note "checking referential integrity: every granted helper exists in the catalog"
for mode in $modes; do
  for helper in $(spec_get ".modes[\"$mode\"].commands.grants[]"); do
    jq -e --arg h "$helper" '.helpers | has($h)' "$spec" >/dev/null \
      || fail "$mode: grants $helper, which is not in the helper catalog"
  done
  for helper in $(spec_get ".modes[\"$mode\"].egress.via[]? // empty"); do
    jq -e --arg h "$helper" '.modes["'"$mode"'"].commands.grants | index($h)' "$spec" >/dev/null \
      || fail "$mode: egress names $helper but commands.grants does not"
  done
done

note "checking the prompt names every granted helper and no ungranted one"
for target in claude codex; do
  for mode in $modes; do
    prompt="$prefix/share/prompts/$target/$mode.prompt.md"
    for helper in $(jq -r '.helpers | keys[]' "$spec"); do
      if jq -e --arg h "$helper" '.modes["'"$mode"'"].commands.grants | index($h)' "$spec" >/dev/null; then
        assert_contains "$prompt" "$helper"
      else
        assert_not_contains "$prompt" "\`$helper\`"
      fi
    done
  done
done

note "checking the prompt advertises an MCP server only where the table grants one"
for target in claude codex; do
  for mode in $modes; do
    prompt="$prefix/share/prompts/$target/$mode.prompt.md"
    if [ "$(spec_get ".modes[\"$mode\"].mcp | length")" = "0" ]; then
      assert_not_contains "$prompt" "Zotero"
      if [ "$target" = "codex" ]; then
        assert_contains "$prompt" "run_as_user command carrier is loaded; no mode-granted MCP servers are loaded."
      else
        assert_contains "$prompt" "No MCP servers are loaded."
      fi
    else
      assert_contains "$prompt" "Zotero"
    fi
    if [ "$target" = "codex" ]; then
      assert_contains "$prompt" "run_as_user"
    else
      assert_not_contains "$prompt" "run_as_user"
    fi
    if [ "$target" = "claude" ]; then
      assert_contains "$prompt" "User, project, and local Claude settings are loaded temporarily"
      assert_contains "$prompt" "Unlisted MCP servers and the Chrome integration remain disabled."
    else
      assert_contains "$prompt" "Inherited user-configurable settings, hooks, rules, plugins, apps, connectors, browser control, computer use, native image generation, and unlisted MCP servers are disabled."
    fi
    assert_contains "$prompt" "Organization-managed policy remains authoritative and is outside the user-configurable mode matrix."
  done
done

printf 'ok - installed artifacts match the capability table\n'
