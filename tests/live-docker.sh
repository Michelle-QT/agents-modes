#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require_cmd python3

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

require_cmd git

# The `# case:` tokens below are the cross-check surface: every coverage row with
# runner=container must name a case this file carries, asserted by test-table.sh.
work="$(tmp_dir live-docker-work)"
mkdir -p "$work/sandbox-escapes" "$work/container" "$work/nested"
git init -q "$work"
git -C "$work" config user.email test@example.invalid
git -C "$work" config user.name test
printf 'escape-original' > "$work/sandbox-escapes/original"
printf 'container-original' > "$work/container/original"
printf 'SECRET_FROM_WORKDIR\n' > "$work/.env"
printf 'NESTED_SECRET\n' > "$work/nested/.env"
printf 'PEM_SECRET\n' > "$work/nested/key.pem"
printf 'KEY_SECRET\n' > "$work/nested/id_rsa"

git_config_before="$(cksum "$work/.git/config")"

note "starting live Research container"
(
  cd "$work"
  box_start
  container="$RUNBOX_CONTAINER"
  trap box_stop EXIT

  env -u AGENTS_CLAUDE_MODE CODEX_SANDBOX=seatbelt AGENTS_CODEX_MODE=research RUNBOX_CONTAINER="$container" "$ROOT/container/runbox" sh -lc '
    test "$(pwd)" = "'"$work"'"
    test "$HOME" = "/tmp"
    # case: container-outside-invisible
    test ! -e /Users
    # case: container-workdir-only
    if printf x > /Users/agents-modes-probe 2>/dev/null; then exit 13; fi
    printf ok > live-write.txt
    # case: container-env-mask
    if cat .env >/tmp/leaked-secret 2>/dev/null; then exit 12; fi
    # case: container-nested-secret-mask
    if cat nested/.env >/tmp/leaked-secret 2>/dev/null; then exit 14; fi
    if cat nested/key.pem >/tmp/leaked-secret 2>/dev/null; then exit 15; fi
    if cat nested/id_rsa >/tmp/leaked-secret 2>/dev/null; then exit 16; fi
    # case: container-git-config
    if printf x >> .git/config 2>/dev/null; then exit 17; fi
    if printf x > .git/hooks/agents-modes-probe 2>/dev/null; then exit 18; fi
    if printf planted > sandbox-escapes/planted 2>/dev/null; then exit 10; fi
    if printf planted > container/planted 2>/dev/null; then exit 11; fi
  '
  [ "$(cat "$work/live-write.txt")" = "ok" ] || fail "runbox did not write through the mounted workdir"
  [ "$(cat "$work/sandbox-escapes/original")" = "escape-original" ] || fail "runbox changed sandbox-escapes content"
  [ "$(cat "$work/container/original")" = "container-original" ] || fail "runbox changed container content"
  [ ! -e "$work/sandbox-escapes/planted" ] || fail "runbox planted a project escape"
  [ ! -e "$work/container/planted" ] || fail "runbox changed the project container definition"
  [ ! -e "$work/.git/hooks/agents-modes-probe" ] || fail "runbox wrote into .git/hooks"
  [ "$(cksum "$work/.git/config")" = "$git_config_before" ] || fail "runbox changed .git/config"

  box_stop
  trap - EXIT
  if "$docker_bin" inspect "$container" >/dev/null 2>&1; then
    fail "container still exists after box_stop"
  fi
)
