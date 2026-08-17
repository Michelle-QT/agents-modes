# shellcheck shell=bash

codex_forward_helper_if_active() {
  local helper="$1"
  shift
  [ "${AGENTS_CODEX_DISPATCH_HOST:-0}" != "1" ] || return 0
  [ -n "${AGENTS_CODEX_DISPATCH_DIR:-}" ] || return 0
  local shim="$AGENTS_CODEX_DISPATCH_DIR/$helper"
  if [ ! -x "$shim" ]; then
    echo "$helper: unavailable in Codex mode ${AGENTS_CODEX_MODE:-unknown}" >&2
    exit 2
  fi
  exec "$shim" "$@"
}
