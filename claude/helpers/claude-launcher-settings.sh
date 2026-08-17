# shellcheck shell=bash

# Renders an installed settings file for the project being launched.
#
# Settings are authored with project-relative guards (`./sandbox-escapes/**`) but live in
# a share dir and reach Claude as a JSON string via --settings, so a `./` path has no
# project to anchor to and would silently guard nothing. Absolutizing against $PWD at
# launch is what makes the forbidden row actually bind to the repo you started in.
#
# Every `./` entry is rewritten, not a hardcoded list of them: the forbidden row is data
# in modes.json, and a guard that appeared there but not here would fail open.
claude_validate_mode_args() {
  local arg after_separator=0 expect_model=0 expect_resume_value=0 print_mode=0
  claude_mode_resume=0
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
    if [ "$expect_resume_value" = "1" ]; then
      expect_resume_value=0
      case "$arg" in
        -*) ;;
        *)
          print_mode=1
          continue
          ;;
      esac
    fi
    case "$arg" in
      --add-dir|--add-dir=*|--agent|--agent=*|--agents|--agents=*|--allow-dangerously-skip-permissions|--allowedTools|--allowedTools=*|--allowed-tools|--allowed-tools=*|--bare|--chrome|--dangerously-skip-permissions|--disallowedTools|--disallowedTools=*|--disallowed-tools|--disallowed-tools=*|--file|--file=*|--fork-session|--from-pr|--from-pr=*|--ide|--mcp-config|--mcp-config=*|--permission-mode|--permission-mode=*|--plugin-dir|--plugin-dir=*|--plugin-url|--plugin-url=*|--remote-control|--remote-control=*|--safe-mode|--setting-sources|--setting-sources=*|--settings|--settings=*|--strict-mcp-config|--system-prompt|--system-prompt=*|--system-prompt-file|--system-prompt-file=*|--tools|--tools=*|--worktree|--worktree=*)
        printf 'claude mode launcher: refused policy or integration override: %s\n' "$arg" >&2
        return 2
        ;;
      agents|mcp|plugin|plugins)
        if [ "$print_mode" = "0" ]; then
          printf 'claude mode launcher: refused non-session subcommand: %s\n' "$arg" >&2
          return 2
        fi
        ;;
      -c|--continue)
        claude_mode_resume=1
        print_mode=1
        ;;
      -r|--resume)
        claude_mode_resume=1
        expect_resume_value=1
        ;;
      -r?*|--resume=*)
        claude_mode_resume=1
        print_mode=1
        ;;
      -p|--print) print_mode=1 ;;
      -m|--model) expect_model=1 ;;
    esac
  done
}

claude_prepare_session_settings() {
  local base_settings="$1"
  local output_var="$2"
  local settings_root="$3"
  local agents_root="$4"
  local helper_root="$5"
  local project_root protected_roots generated_settings
  project_root="$(pwd -P)"
  settings_root="$(cd "$settings_root" && pwd -P)"
  agents_root="$(cd "$agents_root" && pwd -P)"
  helper_root="$(cd "$helper_root" && pwd -P)"
  protected_roots="$(jq -cn '$ARGS.positional | unique' --args \
    "$settings_root" "$agents_root" "$helper_root")"
  generated_settings="$(
    jq \
      --arg root "$project_root" \
      --argjson protected "$protected_roots" \
      '
        def absolutize:
          if startswith("./") then $root + ltrimstr(".")
          else .
          end;
        if .sandbox.filesystem.denyWrite then
          .sandbox.filesystem.denyWrite |= map(absolutize)
        else . end
        | if .sandbox.filesystem.allowRead then
            .sandbox.filesystem.allowRead |= map(absolutize)
          else . end
        | reduce $protected[] as $path (.;
            .sandbox.filesystem.denyWrite += [$path, $path + "/**"]
            | .permissions.ask += ["Edit(/" + $path + "/**)"])
        | .sandbox.filesystem.denyWrite |= unique
        | .permissions.ask |= unique
      ' \
      "$base_settings"
  )"
  printf -v "$output_var" '%s' "$generated_settings"
}
