# shellcheck shell=bash

codex_toml_string() {
  python3 -c 'import json, sys; sys.stdout.write(json.dumps(sys.argv[1]))' "$1"
}

codex_render_session_profile() {
  python3 - "$@" <<'PY'
import json
import pathlib
import sys

source, table, _session, auth, project, config, helpers = sys.argv[1:]
lines = pathlib.Path(source).read_text().splitlines()
rendered = []
insertions = 0
in_workspace_roots = False

for line in lines:
    if line.startswith("["):
        in_workspace_roots = line.endswith('.filesystem.":workspace_roots"]')
    if in_workspace_roots and line.endswith(' = "read"'):
        key = json.loads(line.removesuffix(' = "read"'))
        relative = pathlib.Path(key.removesuffix("/**"))
        if not relative.is_absolute() and not (pathlib.Path.cwd() / relative).parent.exists():
            continue
    rendered.append(line)
    if line != table:
        continue
    insertions += 1
    protected = [(config, "read")]
    if helpers != config:
        protected.append((helpers, "read"))
    protected.append((auth, "deny"))
    for path, access in protected:
        rendered.append(f"{json.dumps(path)} = {json.dumps(access)}")
        if access == "read":
            rendered.append(f"{json.dumps(path + '/**')} = {json.dumps(access)}")

if insertions != 1:
    raise SystemExit(f"expected exactly one {table} table, found {insertions}")
rendered.extend(["", f"[projects.{json.dumps(project)}]", 'trust_level = "untrusted"'])
sys.stdout.write("\n".join(rendered) + "\n")
PY
}

codex_render_session_config() {
  python3 - "$@" <<'PY'
import json
import os
import pathlib
import sys

source, helper_root, executable, environment_snapshot = sys.argv[1:]
text = pathlib.Path(source).read_text()
source_command = f"command = {json.dumps(executable)}"
rendered_command = f"command = {json.dumps(os.path.join(helper_root, executable))}"
source_args = 'args = ["__AGENTS_RUN_AS_USER_ENVIRONMENT__"]'
rendered_args = f"args = [{json.dumps(environment_snapshot)}]"
if text.count(source_command) != 1:
    raise SystemExit(f"expected one run_as_user executable line, found {text.count(source_command)}")
if text.count(source_args) != 1:
    raise SystemExit(f"expected one run_as_user environment placeholder, found {text.count(source_args)}")
text = text.replace(source_command, rendered_command)
text = text.replace(source_args, rendered_args)
sys.stdout.write(text)
PY
}

codex_load_config_args() {
  local override
  codex_mode_config_args=()
  while IFS= read -r -d '' override; do
    codex_mode_config_args+=(--config "$override")
  done < <(python3 - "$1" <<'PY'
import json
import pathlib
import re
import sys
import tomllib

config = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())

def toml_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (str, int, float)):
        return json.dumps(value)
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(item) for item in value) + "]"
    raise SystemExit(f"unsupported generated config value: {value!r}")

def walk(value, path=()):
    for key, child in value.items():
        next_path = path + (key,)
        if isinstance(child, dict):
            yield from walk(child, next_path)
        else:
            dotted = ".".join(
                part if re.fullmatch(r"[A-Za-z0-9_-]+", part) else json.dumps(part)
                for part in next_path
            )
            yield f"{dotted}={toml_value(child)}"

sys.stdout.buffer.write(b"\0".join(item.encode() for item in walk(config)) + b"\0")
PY
  )
}

codex_diagnose_sandbox() {
  local mode="$1"
  local profile="$2"
  local profile_source="$3"
  local config_source="$4"
  local rules_source="$5"
  local helper_root="$6"
  local run_as_user_executable="$7"
  local root case_name launch_dir stderr status detail
  local -a cases=(
    "root-missing"
    "root-claude"
    "root-all"
    "subdir-missing"
    "subdir-claude"
    "subdir-all"
  )

  root="$(mktemp -d "${TMPDIR:-/tmp}/agents-modes-sandbox-diagnosis.XXXXXX")"
  trap 'rm -rf "$root"' RETURN
  printf 'codex=%s\n' "$(
    codex --version 2>&1 | awk '
      /codex-cli/ { print; found = 1; exit }
      NR == 1 { first = $0 }
      END { if (!found) print first }
    '
  )"
  printf 'system=%s\n' "$(uname -srm)"
  if command -v bwrap >/dev/null 2>&1; then
    printf 'bwrap=%s\n' "$(command -v bwrap)"
  else
    printf 'bwrap=absent\n'
  fi

  for case_name in "${cases[@]}"; do
    mkdir -p "$root/$case_name/project/subdir"
    git -C "$root/$case_name/project" init -q
    case "$case_name" in
      *-claude)
        mkdir -p "$root/$case_name/project/.claude"
        ;;
      *-all)
        mkdir -p \
          "$root/$case_name/project/.claude" \
          "$root/$case_name/project/.codex" \
          "$root/$case_name/project/sandbox-escapes" \
          "$root/$case_name/project/container"
        ;;
    esac
    case "$case_name" in
      root-*) launch_dir="$root/$case_name/project" ;;
      subdir-*) launch_dir="$root/$case_name/project/subdir" ;;
    esac
    stderr="$root/$case_name.stderr"
    status=0
    (
      cd "$launch_dir"
      codex_start_mode_session \
        "$mode" "$profile" "$profile_source" "$config_source" "$rules_source" \
        "$helper_root" "$run_as_user_executable"
      trap codex_stop_mode_session EXIT
      codex --profile "$profile" "${codex_mode_config_args[@]}" sandbox -- /bin/true
    ) > /dev/null 2>"$stderr" || status=$?
    if [ "$status" -eq 0 ]; then
      printf 'case=%s result=pass\n' "$case_name"
    else
      detail="$(
        awk '
          NF && first == "" { first = $0 }
          /bwrap:|error:/ { gsub(/[[:space:]]+/, " "); print; found = 1; exit }
          END {
            if (!found && first != "") {
              gsub(/[[:space:]]+/, " ", first)
              print first
            }
          }
        ' "$stderr"
      )"
      printf 'case=%s result=fail status=%s detail=%s\n' \
        "$case_name" "$status" "${detail:-no-error-text}"
    fi
  done
}

codex_validate_mode_args() {
  local arg after_separator=0 expect_debug_command=0 expect_model=0 session_started=0
  for arg in "$@"; do
    if [ "$after_separator" = "1" ]; then
      continue
    fi
    if [ "$arg" = "--" ]; then
      after_separator=1
      continue
    fi
    if [ "$expect_model" = "1" ]; then
      expect_model=0
      continue
    fi
    if [ "$expect_debug_command" = "1" ]; then
      if [ "$arg" != "prompt-input" ]; then
        printf 'codex mode launcher: refused debug subcommand: %s\n' "$arg" >&2
        return 2
      fi
      expect_debug_command=0
      session_started=1
      continue
    fi
    case "$arg" in
      -a|-a?*|-C|-C?*|-c|-c?*|-i|-i?*|-p|-p?*|-s|-s?*|--add-dir|--add-dir=*|--ask-for-approval|--ask-for-approval=*|--cd|--cd=*|--config|--config=*|--dangerously-bypass-approvals-and-sandbox|--dangerously-bypass-hook-trust|--disable|--disable=*|--enable|--enable=*|--ignore-rules|--ignore-user-config|--image|--image=*|--local-provider|--local-provider=*|--oss|--profile|--profile=*|--remote|--remote=*|--remote-auth-token-env|--remote-auth-token-env=*|--sandbox|--sandbox=*|--search)
        printf 'codex mode launcher: refused policy or integration override: %s\n' "$arg" >&2
        return 2
        ;;
      debug)
        if [ "$session_started" = "0" ]; then
          expect_debug_command=1
          continue
        fi
        ;;
      app|app-server|apply|archive|cloud|completion|delete|doctor|exec-server|features|fork|help|login|logout|mcp|mcp-server|plugin|remote-control|sandbox|unarchive|update)
        if [ "$session_started" = "0" ]; then
          printf 'codex mode launcher: refused non-session subcommand: %s\n' "$arg" >&2
          return 2
        fi
        ;;
    esac
    case "$arg" in
      -m|--model) expect_model=1 ;;
      --model=*|-*) ;;
      *) session_started=1 ;;
    esac
  done
  if [ "$expect_debug_command" = "1" ]; then
    printf 'codex mode launcher: debug requires the prompt-input subcommand\n' >&2
    return 2
  fi
}

codex_start_mode_session() {
  local mode="$1"
  local profile="$2"
  local profile_source="$3"
  local config_source="$4"
  local rules_source="$5"
  local helper_root="$6"
  local run_as_user_executable="$7"
  local source_home session_parent auth_home auth_source project_root config_root
  local environment_snapshot rendered_config rendered_profile state_dir

  source_home="${CODEX_HOME:-$HOME/.codex}"
  if [ ! -d "$source_home" ]; then
    install -d -m 0700 "$source_home"
  fi
  source_home="$(cd "$source_home" && pwd -P)"
  session_parent="${AGENTS_CODEX_SESSION_DIR:-${AGENTS_MODES_DIR:-$HOME/.local/share/agents-modes}/codex-sessions}"
  install -d -m 0700 "$session_parent"
  codex_session_home="$(mktemp -d "$session_parent/session.XXXXXX")"
  chmod 0700 "$codex_session_home"
  codex_session_profile_file="$codex_session_home/$profile.config.toml"
  codex_session_config_file="$codex_session_home/config.toml"
  codex_session_mode_config_file="$codex_session_home/mode.config.toml"
  codex_session_state_home="$source_home"
  for state_dir in sessions archived_sessions; do
    if [ ! -d "$source_home/$state_dir" ]; then
      install -d -m 0700 "$source_home/$state_dir"
    fi
    ln -s "$source_home/$state_dir" "$codex_session_home/$state_dir"
  done
  if [ ! -e "$source_home/session_index.jsonl" ]; then
    install -m 0600 /dev/null "$source_home/session_index.jsonl"
  fi
  ln -s "$source_home/session_index.jsonl" "$codex_session_home/session_index.jsonl"

  helper_root="$(cd "$helper_root" && pwd -P)"
  [ -x "$helper_root/$run_as_user_executable" ] || {
    printf 'codex launcher: run_as_user carrier not found at %s\n' "$helper_root/$run_as_user_executable" >&2
    return 1
  }
  environment_snapshot="$codex_session_home/run-as-user.environment"
  /usr/bin/env -0 > "$environment_snapshot"
  chmod 0600 "$environment_snapshot"
  rendered_config="$codex_session_home/mode-config.new"
  codex_render_session_config \
    "$config_source" "$helper_root" "$run_as_user_executable" "$environment_snapshot" \
    > "$rendered_config"
  if [ -f "$source_home/config.toml" ]; then
    install -m 0600 "$source_home/config.toml" "$codex_session_config_file"
  else
    install -m 0600 /dev/null "$codex_session_config_file"
  fi
  install -m 0600 "$rendered_config" "$codex_session_mode_config_file"
  install -d -m 0700 "$codex_session_home/rules"
  install -m 0600 "$rules_source" "$codex_session_home/rules/agents-modes.rules"
  codex_load_config_args "$codex_session_mode_config_file"

  auth_home="${AGENTS_MODES_CODEX_AUTH_HOME:-$source_home}"
  auth_source="$auth_home/auth.json"
  if [ -e "$auth_source" ]; then
    ln -s "$auth_source" "$codex_session_home/auth.json"
  fi
  if [ -f "$auth_home/installation_id" ]; then
    install -m 0600 "$auth_home/installation_id" "$codex_session_home/installation_id"
  fi

  project_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd -P)"
  config_root="$(cd "$(dirname "$profile_source")/../.." && pwd -P)"
  rendered_profile="$codex_session_home/profile.new"
  codex_render_session_profile "$profile_source" "[permissions.$profile.filesystem]" \
    "$codex_session_home" "$auth_source" "$project_root" "$config_root" "$helper_root" \
    > "$rendered_profile"
  install -m 0600 "$rendered_profile" "$codex_session_profile_file"
  rm -f "$rendered_profile" "$rendered_config"

  export CODEX_SQLITE_HOME="$codex_session_home"
  export CODEX_HOME="$codex_session_home"
}

codex_stop_mode_session() {
  local parent
  [ -n "${codex_session_home:-}" ] || return 0
  parent="${AGENTS_CODEX_SESSION_DIR:-${AGENTS_MODES_DIR:-$HOME/.local/share/agents-modes}/codex-sessions}"
  case "$codex_session_home" in
    "$parent"/session.*) rm -rf "$codex_session_home" ;;
    *) printf 'codex-launcher-session: refused to remove unexpected session path: %s\n' "$codex_session_home" >&2 ;;
  esac
  codex_session_home=
  codex_session_config_file=
  codex_session_mode_config_file=
  codex_session_state_home=
  codex_mode_config_args=()
}
