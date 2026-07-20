#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require_cmd git

sandbox_escape="$ROOT/helpers/sandbox-escape"
fetch_all="$ROOT/modes/development/fetch-all"
ls_remote="$ROOT/modes/development/ls-remote"
gh_ro="$ROOT/modes/development/gh-ro"
runbox="$ROOT/container/runbox"
boxlib="$ROOT/container/boxlib.sh"

note "checking sandbox-escape behavior"
project="$(tmp_dir sandbox-escape)"
mkdir -p "$project/sandbox-escapes"
cat > "$project/sandbox-escapes/hello" <<'SH'
#!/usr/bin/env bash
printf 'hello:%s\n' "$1"
SH
chmod +x "$project/sandbox-escapes/hello"
ln -s hello "$project/sandbox-escapes/link"

(
  cd "$project"
  assert_output_contains "hello:ok" env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$sandbox_escape" hello ok
  assert_output_contains "hello:ok" env -u AGENTS_CLAUDE_MODE CODEX_SANDBOX=seatbelt AGENTS_CODEX_MODE=development "$sandbox_escape" hello ok
  assert_output_contains "hello:ok" env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=sealed-development "$sandbox_escape" ./sandbox-escapes/hello ok
  assert_failure env -u AGENTS_CLAUDE_MODE -u AGENTS_CODEX_MODE -u CODEX_SANDBOX "$sandbox_escape" hello ok
  assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=research "$sandbox_escape" hello ok
  assert_failure env -u AGENTS_CLAUDE_MODE CODEX_SANDBOX=seatbelt AGENTS_CODEX_MODE=research "$sandbox_escape" hello ok
  assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$sandbox_escape" ../hello ok
  assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$sandbox_escape" link ok
  assert_failure env -u AGENTS_CLAUDE_MODE CODEX_SANDBOX=seatbelt AGENTS_CODEX_MODE=development "$sandbox_escape" ../hello ok
  assert_failure env -u AGENTS_CLAUDE_MODE CODEX_SANDBOX=seatbelt AGENTS_CODEX_MODE=development "$sandbox_escape" link ok
)

note "checking Development git helper guards"
repo="$(tmp_dir git-repo)"
git init -q "$repo"
(
  cd "$repo"
  assert_success env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$fetch_all"
  assert_success env -u AGENTS_CLAUDE_MODE CODEX_SANDBOX=seatbelt AGENTS_CODEX_MODE=development "$fetch_all"
  assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=sealed-development "$fetch_all"
  assert_failure env -u AGENTS_CLAUDE_MODE CODEX_SANDBOX=seatbelt AGENTS_CODEX_MODE=sealed-development "$fetch_all"
  assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$fetch_all" extra
  git remote add origin 'ext::sh -c true'
  assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$fetch_all"
  assert_failure env -u AGENTS_CLAUDE_MODE CODEX_SANDBOX=seatbelt AGENTS_CODEX_MODE=development "$ls_remote"
)

note "checking gh-ro refusal paths"
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=sealed-development "$gh_ro" pr view 1
assert_failure env -u AGENTS_CLAUDE_MODE CODEX_SANDBOX=seatbelt AGENTS_CODEX_MODE=sealed-development "$gh_ro" pr view 1
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$gh_ro" pr create
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$gh_ro" api graphql
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$gh_ro" api --method POST /rate_limit
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$gh_ro" pr view --hostname example.com 1
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$gh_ro" pr view HTTPS://example.com/owner/repo/pull/1
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$gh_ro" pr view -R example.com/owner/repo 1
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$gh_ro" pr view --repo=example.com/owner/repo 1
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development GH_REPO=example.com/owner/repo "$gh_ro" repo view example.com/owner/repo
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$gh_ro" api //example.com/rate_limit
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$gh_ro" api --input=payload.json /rate_limit
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$gh_ro" api -Fquery=secret /rate_limit
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$gh_ro" api -H 'X-HTTP-Method-Override: POST' /rate_limit
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$gh_ro" api --header='Host: example.com' /rate_limit
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$gh_ro" api --cache=1h /rate_limit
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$gh_ro" auth status --show-token
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development "$gh_ro" repo view owner/repo --web

note "checking runbox guards before Docker access"
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=development RUNBOX_CONTAINER=agents-box-test "$runbox" true
assert_failure env -u AGENTS_CLAUDE_MODE CODEX_SANDBOX=seatbelt AGENTS_CODEX_MODE=development RUNBOX_CONTAINER=agents-box-test "$runbox" true
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=research "$runbox" true
assert_failure env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX AGENTS_CLAUDE_MODE=research RUNBOX_CONTAINER=wrong "$runbox" true
assert_failure env -u AGENTS_CLAUDE_MODE CODEX_SANDBOX=seatbelt AGENTS_CODEX_MODE=research RUNBOX_CONTAINER='agents-box-bad*' "$runbox" true

note "checking Docker socket discovery"
docker_short_root="$(tmp_dir docker-socket)"
docker_home="$docker_short_root/home"
docker_config="$docker_short_root/config"
docker_socket="$docker_home/.docker/run/docker.sock"
docker_env="$(
  env -u DOCKER_HOST HOME="$docker_home" AGENTS_DOCKER_CONFIG="$docker_config" bash -c '
    . "$1"
    expected_socket="$2"
    _box_is_socket() { [ "$1" = "$expected_socket" ]; }
    _box_set_docker_config
    printf "%s\n%s\n" "$DOCKER_CONFIG" "$DOCKER_HOST"
  ' bash "$boxlib" "$docker_socket"
)"
expected_docker_env="${docker_config}
unix://${docker_socket}"
[ "$docker_env" = "$expected_docker_env" ] || fail "boxlib did not select the Docker Desktop socket"
preserved_host="$(
  env DOCKER_HOST=unix:///already-set HOME="$docker_home" AGENTS_DOCKER_CONFIG="$docker_config" bash -c '
    . "$1"
    _box_set_docker_config
    printf "%s\n" "$DOCKER_HOST"
  ' bash "$boxlib"
)"
[ "$preserved_host" = "unix:///already-set" ] || fail "boxlib did not preserve an existing DOCKER_HOST"

note "checking Research policy mask temp base"
policy_parent="$(tmp_dir policy-parent)"
policy_tmpdir="$(tmp_dir policy-tmpdir)"
policy_template="$(
  env TMPDIR="$policy_tmpdir" AGENTS_BOX_POLICY_TMPDIR="$policy_parent" bash -c '
    . "$1"
    _box_policy_tmp_template
  ' bash "$boxlib"
)"
[ "$policy_template" = "$policy_parent/agents-modes-box-policy.XXXXXX" ] \
  || fail "boxlib ignored AGENTS_BOX_POLICY_TMPDIR for policy masks"
if [ -d /private/tmp ] && [ -w /private/tmp ]; then
  default_policy_template="$(
    env TMPDIR="$policy_tmpdir" bash -c '
      . "$1"
      _box_policy_tmp_template
    ' bash "$boxlib"
  )"
  [ "$default_policy_template" = "/private/tmp/agents-modes-box-policy.XXXXXX" ] \
    || fail "boxlib did not prefer /private/tmp for Docker policy masks"
fi
policy_work="$(tmp_dir policy-mounts)"
printf 'secret\n' > "$policy_work/.env"
(
  . "$boxlib"
  export AGENTS_BOX_POLICY_TMPDIR="$policy_parent"
  AGENTS_BOX_SECRET_GLOBS=("**/.env")
  AGENTS_BOX_FORBIDDEN_PROJECT_PATHS=()
  _box_prepare_policy_mounts "$policy_work"
  case "$BOX_POLICY_TMP" in
    "$policy_parent"/agents-modes-box-policy.*) ;;
    *) fail "policy mask dir was not created under the Docker-shareable temp base" ;;
  esac
  policy_mask="$BOX_POLICY_TMP/mask-0"
  [ -r "$policy_mask" ] || fail "policy mask source was locked before Docker could mount it"
  case " ${BOX_POLICY_MOUNTS[*]} " in
    *":$policy_work/.env:ro "*) ;;
    *) fail "policy mask mount was not generated for in-tree secret" ;;
  esac
  _box_lock_policy_mounts
  [ ! -r "$policy_mask" ] || fail "policy mask source was not locked after container start"
  policy_created="$BOX_POLICY_TMP"
  _box_cleanup_policy_mounts
  [ ! -e "$policy_created" ] || fail "policy mask temp dir was not cleaned up"
)

note "checking Research reserved-directory mounts"
reserved_work="$(tmp_dir reserved-mounts)"
(
  . "$boxlib"
  _box_prepare_reserved_mounts "$reserved_work"
  [ -d "$reserved_work/sandbox-escapes" ] || fail "sandbox-escapes placeholder was not created"
  [ -d "$reserved_work/container" ] || fail "container placeholder was not created"
  [ "${#BOX_RESERVED_MOUNTS[@]}" -eq 4 ] || fail "reserved mount arguments were not generated"
  case " ${BOX_RESERVED_MOUNTS[*]} " in
    *" $reserved_work/sandbox-escapes:$reserved_work/sandbox-escapes:ro "*) ;;
    *) fail "sandbox-escapes was not mounted read-only" ;;
  esac
  case " ${BOX_RESERVED_MOUNTS[*]} " in
    *" $reserved_work/container:$reserved_work/container:ro "*) ;;
    *) fail "container was not mounted read-only" ;;
  esac
  _box_cleanup_reserved_dirs
  [ ! -e "$reserved_work/sandbox-escapes" ] || fail "sandbox-escapes placeholder was not removed"
  [ ! -e "$reserved_work/container" ] || fail "container placeholder was not removed"
)
reserved_invalid="$(tmp_dir reserved-invalid)"
: > "$reserved_invalid/container"
(
  . "$boxlib"
  assert_failure _box_prepare_reserved_mounts "$reserved_invalid"
)
reserved_symlink="$(tmp_dir reserved-symlink)"
reserved_target="$(tmp_dir reserved-symlink-target)"
ln -s "$reserved_target" "$reserved_symlink/sandbox-escapes"
(
  . "$boxlib"
  assert_failure _box_prepare_reserved_mounts "$reserved_symlink"
)

note "checking Docker socket permission failures"
fake_docker_dir="$(tmp_dir fake-docker)"
fake_docker="$fake_docker_dir/docker"
cat > "$fake_docker" <<'SH'
#!/usr/bin/env bash
printf 'permission denied while trying to connect to the Docker daemon socket\n' >&2
exit 1
SH
chmod +x "$fake_docker"
out="$(tmp_dir docker-permission)"
if bash -c '
  . "$1"
  fake_docker="$2"
  _box_find_docker() { printf "%s\n" "$fake_docker"; }
  _box_ensure_docker
' bash "$boxlib" "$fake_docker" >"$out/stdout" 2>"$out/stderr"; then
  fail "boxlib unexpectedly accepted an inaccessible Docker socket"
fi
assert_contains "$out/stderr" "Docker socket is present but not accessible from this session"

note "checking every mode x helper guard agrees with modes.json"
# The helpers' mode guards stay hand-written on purpose: they are an independent second
# gate, compiled in and free of any environment-supplied policy. Duplication there is a
# feature, so pin it rather than remove it. Behavioural, not textual, so it survives a
# refactor of the guard's shape; exhaustive on the deny direction, which is the
# security-relevant one; both targets carry the same slug under symmetric variable names.
helper_path() {
  case "$1" in
    sandbox-escape) printf '%s\n' "$ROOT/helpers/sandbox-escape" ;;
    runbox)         printf '%s\n' "$ROOT/container/runbox" ;;
    *)              printf '%s\n' "$ROOT/modes/development/$1" ;;
  esac
}

guard_probe="$(tmp_dir guard-probe)"
for mode in $(jq -r '.modes | keys[]' "$ROOT/modes.json"); do
  for helper in $(jq -r '.helpers | keys[]' "$ROOT/modes.json"); do
    path="$(helper_path "$helper")"
    granted=no
    jq -e --arg m "$mode" --arg h "$helper" '.modes[$m].commands.grants | index($h)' \
      "$ROOT/modes.json" >/dev/null && granted=yes
    for target in claude codex; do
      if [ "$target" = claude ]; then
        env_args=(env -u AGENTS_CODEX_MODE -u CODEX_SANDBOX "AGENTS_CLAUDE_MODE=$mode")
      else
        env_args=(env -u AGENTS_CLAUDE_MODE CODEX_SANDBOX=seatbelt "AGENTS_CODEX_MODE=$mode")
      fi
      out="$guard_probe/$mode.$helper.$target"
      # No arguments: a granted helper gets past the guard and fails on usage/arity, so
      # the probe never performs the helper's real action. A denied one never gets there.
      ( cd "$guard_probe" && "${env_args[@]}" "$path" ) >"$out.stdout" 2>"$out.stderr" || true
      if [ "$granted" = yes ]; then
        if grep -Fq 'available only in' "$out.stderr"; then
          fail "$mode/$target: $helper is granted by modes.json but its guard refuses it"
        fi
      else
        grep -Fq 'available only in' "$out.stderr" \
          || fail "$mode/$target: $helper is not granted by modes.json but its guard let it past"
      fi
    done
  done
done
