#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require_cmd python3

# No env gate: this file reaches the public internet, so it runs only from
# `make test-network`, which is the only target that names it.

export AGENTS_CONTAINER_DIR="$ROOT/container"
export AGENTS_CONTAINER_POLICY="$TEST_TMP_ROOT/container-policy.sh"
export AGENTS_DOCKER_CONFIG="$TEST_TMP_ROOT/docker-config"
python3 "$ROOT/tools/agents-modes-gen" container-policy-sh > "$AGENTS_CONTAINER_POLICY"
# shellcheck source=/dev/null
. "$ROOT/container/boxlib.sh"
_box_set_docker_config
docker_bin="$(_box_find_docker)" || skip "docker CLI not found on a trusted absolute path"
if ! info="$("$docker_bin" info 2>&1)"; then
  case "$info" in
    *"permission denied"*|*"operation not permitted"*|*"Operation not permitted"*)
      skip "Docker socket is present but not accessible from this session"
      ;;
    *)
      skip "docker daemon is not running"
      ;;
  esac
fi

if ! "$docker_bin" image inspect agents-box:base >/dev/null 2>&1; then
  [ "${AGENTS_MODES_LIVE_BUILD:-0}" = "1" ] || skip "agents-box:base is missing; set AGENTS_MODES_LIVE_BUILD=1 to allow building it"
fi

work="$(tmp_dir live-network-work)"
mkdir -p "$work"

note "checking live Research container egress"
(
  cd "$work"
  box_start
  trap box_stop EXIT
  env -u AGENTS_CLAUDE_MODE CODEX_SANDBOX=seatbelt AGENTS_CODEX_MODE=research RUNBOX_CONTAINER="$RUNBOX_CONTAINER" "$ROOT/container/runbox" curl -fsSL --max-time 10 https://example.com/ >/dev/null
)
