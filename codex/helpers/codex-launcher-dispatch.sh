# shellcheck shell=bash

codex_dispatch_dir=""
codex_dispatch_pid=""

# Starts the shim dir for a mode's granted helpers.
#
# With no helper arguments, the grant and shim set are read from the mode's generated
# manifest, so the capability decision lives in modes.json rather than in four
# launchers' argv. Explicit arguments still win, which keeps the dispatcher testable
# without an install.
#
# Reading a file is safe HERE and would not be inside a helper: this runs before the
# agent exists, outside any sandbox, with the user's environment, so $AGENTS_MODES_DIR is
# not agent-influenced. The manifest dir is also on the forbidden list, so no mode can
# write it. The helpers' own mode guards stay hand-written on purpose: they are an
# independent second gate, and duplication there is a feature.
codex_start_helper_dispatch() {
  local mode="$1"
  local helper_dir="$2"
  local workdir="$PWD"
  shift 2
  local dispatcher="$helper_dir/codex-helper-dispatch"
  local helper
  local -a allowed=()
  local -a shims=()
  [ -x "$dispatcher" ] || {
    echo "codex launcher: helper dispatcher not found at $dispatcher (run 'make codex')" >&2
    exit 1
  }
  if [ "$#" -eq 0 ]; then
    local dir manifest
    dir="${AGENTS_MODES_DIR:-$HOME/.local/share/agents-modes}"
    manifest="$dir/modes/$mode.json"
    [ -f "$manifest" ] || {
      echo "codex launcher: mode manifest not found at $manifest (run 'make codex')" >&2
      exit 1
    }
    while IFS= read -r helper; do
      [ -n "$helper" ] && allowed+=("$helper")
    done < <(jq -r '.grants[]' "$manifest")
    while IFS= read -r helper; do
      [ -n "$helper" ] && shims+=("$helper")
    done < <(jq -r '(.shims // .grants)[]' "$manifest")
    [ "${#allowed[@]}" -gt 0 ] || {
      echo "codex launcher: no helpers granted in $mode" >&2
      exit 1
    }
  else
    allowed=("$@")
    shims=("$@")
  fi
  codex_dispatch_dir="$(mktemp -d "${TMPDIR:-/tmp}/agents-modes-codex-dispatch.XXXXXX")"
  chmod 700 "$codex_dispatch_dir"
  for helper in "${shims[@]}"; do
    cat > "$codex_dispatch_dir/$helper" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${AGENTS_CODEX_DISPATCH_DIR:?codex helper dispatcher is not active}"
helper="${0##*/}"
base="$AGENTS_CODEX_DISPATCH_DIR/request.$$.$RANDOM.$RANDOM"
printf '%s' "$helper" > "$base.helper"
printf '%s' "$PWD" > "$base.cwd"
if [ "$#" -eq 0 ]; then
  : > "$base.args"
else
  printf '%s\0' "$@" > "$base.args"
fi
: > "$base.ready"
while [ ! -f "$base.done" ]; do
  sleep 0.05
done
[ ! -f "$base.stdout" ] || cat "$base.stdout"
[ ! -f "$base.stderr" ] || cat "$base.stderr" >&2
status="$(cat "$base.status" 2>/dev/null || printf '1')"
rm -f "$base.helper" "$base.cwd" "$base.args" "$base.ready" "$base.stdout" "$base.stderr" "$base.status" "$base.done"
exit "$status"
SH
    chmod 700 "$codex_dispatch_dir/$helper"
  done
  "$dispatcher" --dir "$codex_dispatch_dir" --mode "$mode" --helper-dir "$helper_dir" --workdir "$workdir" --helpers "${allowed[@]}" &
  codex_dispatch_pid="$!"
  export AGENTS_CODEX_DISPATCH_DIR="$codex_dispatch_dir"
  export PATH="$codex_dispatch_dir:$PATH"
}

codex_stop_helper_dispatch() {
  if [ -n "${codex_dispatch_pid:-}" ]; then
    kill "$codex_dispatch_pid" 2>/dev/null || true
    wait "$codex_dispatch_pid" 2>/dev/null || true
    codex_dispatch_pid=""
  fi
  if [ -n "${codex_dispatch_dir:-}" ]; then
    rm -rf "$codex_dispatch_dir"
    codex_dispatch_dir=""
  fi
  unset AGENTS_CODEX_DISPATCH_DIR
}
