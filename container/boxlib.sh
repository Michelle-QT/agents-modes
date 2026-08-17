# boxlib.sh — container-exec substrate lifecycle (see the `runbox auto` entry in README.md).
#
# Sourced by a mode launcher (currently claude-research). Mode-agnostic: any launcher
# can source this to run its agent alongside a locked, workdir-only container that the
# host-side `runbox` wrapper execs into. Nothing here is Research-specific; Research is
# just the first consumer, so a future boxed Development mode reuses this unchanged.
#
# Public API (call after sourcing, from a bash launcher):
#   box_start   ensure Docker is up, build the base (and optional per-project) image,
#               run the session container, and export RUNBOX_CONTAINER for `runbox`.
#               Returns non-zero (and starts nothing) if Docker cannot be reached, so
#               the launcher can fail clearly.
#   box_stop    force-remove the session container (idempotent; safe to call twice).
#
# Config (env, all optional):
#   AGENTS_CONTAINER_DIR   directory holding the base Dockerfile (default: the installed
#                          ~/.local/share/agents-modes/container)
#   AGENTS_CONTAINER_POLICY generated shell policy for in-container secret and forbidden
#                          path mounts (default: $AGENTS_CONTAINER_DIR/policy.sh)
#   AGENTS_DOCKER_CONFIG   empty Docker CLI config directory used for this substrate
#                          (default: ${TMPDIR:-/tmp}/agents-modes-empty-docker-config)
#   AGENTS_DOCKER_SOCKET   daemon socket path to prefer when DOCKER_HOST is unset
#   AGENTS_BOX_POLICY_TMPDIR
#                          Docker-shareable temp base for unreadable policy-mask bind
#                          mounts (default: /private/tmp when present, then TMPDIR, then /tmp)
#   BOX_BASE_TAG           base image tag (default: agents-box:base)
#
# The session container is unprivileged: all caps dropped, no-new-privileges, run as the
# host UID/GID so files it writes stay user-owned, and only $PWD bind-mounted at the same
# absolute path. The reserved sandbox-escapes/ and container/ subdirectories are overlaid
# read-only so commands in the box cannot plant the next session's privileged inputs. It
# joins the default bridge network for public egress. It is per-session and disposable;
# durable tools belong in a tracked Dockerfile, not a long-lived box.

: "${BOX_BASE_TAG:=agents-box:base}"

_box_set_docker_config() {
  : "${AGENTS_DOCKER_CONFIG:=${TMPDIR:-/tmp}/agents-modes-empty-docker-config}"
  mkdir -p "$AGENTS_DOCKER_CONFIG"
  export DOCKER_CONFIG="$AGENTS_DOCKER_CONFIG"
  [ -n "${DOCKER_HOST:-}" ] && return 0
  local socket
  for socket in \
    "${AGENTS_DOCKER_SOCKET:-}" \
    "$HOME/.docker/run/docker.sock" \
    "$HOME/Library/Containers/com.docker.docker/Data/docker-cli.sock" \
    /var/run/docker.sock; do
    [ -n "$socket" ] || continue
    _box_is_socket "$socket" || continue
    export DOCKER_HOST="unix://$socket"
    return 0
  done
}

_box_is_socket() {
  [ -S "$1" ]
}

_box_find_docker() {
  local candidate
  for candidate in /opt/homebrew/bin/docker /usr/local/bin/docker /usr/bin/docker; do
    [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  candidate="$(command -v docker 2>/dev/null || true)"
  [ -n "$candidate" ] && [ "${candidate#/}" != "$candidate" ] && [ -x "$candidate" ] || return 1
  case "$candidate" in
    "$PWD"/*) return 1 ;;
  esac
  printf '%s\n' "$candidate"
}

_box_dockerfile() {
  printf '%s/Dockerfile' "${AGENTS_CONTAINER_DIR:-$HOME/.local/share/agents-modes/container}"
}

_box_policy_file() {
  printf '%s\n' "${AGENTS_CONTAINER_POLICY:-${AGENTS_CONTAINER_DIR:-$HOME/.local/share/agents-modes/container}/policy.sh}"
}

_box_load_policy() {
  local policy
  policy="$(_box_policy_file)"
  [ -f "$policy" ] || {
    echo "boxlib: generated container policy missing at $policy (run 'make install')" >&2
    return 1
  }
  # shellcheck source=/dev/null
  . "$policy"
  [ "${#AGENTS_BOX_SECRET_GLOBS[@]}" -gt 0 ] || {
    echo "boxlib: generated container policy has no secret globs" >&2
    return 1
  }
  [ "${#AGENTS_BOX_FORBIDDEN_PROJECT_PATHS[@]}" -gt 0 ] || {
    echo "boxlib: generated container policy has no forbidden paths" >&2
    return 1
  }
}

# Ensure the Docker CLI exists and the daemon answers. On macOS, start Docker Desktop
# and wait for it; otherwise fail clearly.
_box_ensure_docker() {
  DOCKER_BIN="$(_box_find_docker)" || {
    echo "boxlib: docker CLI not found on a trusted absolute path; install Docker Desktop and retry" >&2
    return 1
  }
  local info
  if info="$("$DOCKER_BIN" info 2>&1)"; then
    return 0
  fi
  case "$info" in
    *"permission denied"*|*"operation not permitted"*|*"Operation not permitted"*)
      echo "boxlib: Docker socket is present but not accessible from this session" >&2
      echo "$info" >&2
      return 1
      ;;
  esac
  if [ "$(uname -s)" = "Darwin" ] && [ -d /Applications/Docker.app ]; then
    echo "boxlib: Docker daemon is down; starting Docker Desktop and waiting..." >&2
    open -a Docker >/dev/null 2>&1 || true
    local n=0
    while [ "$n" -lt 60 ]; do
      if info="$("$DOCKER_BIN" info 2>&1)"; then
        echo "boxlib: Docker is up." >&2
        return 0
      fi
      case "$info" in
        *"permission denied"*|*"operation not permitted"*|*"Operation not permitted"*)
          echo "boxlib: Docker socket is present but not accessible from this session" >&2
          echo "$info" >&2
          return 1
          ;;
      esac
      sleep 2
      n=$((n + 1))
    done
  fi
  echo "boxlib: Docker daemon is not available; start Docker and retry" >&2
  return 1
}

# Build the base image if absent, then any per-project extension. Sets BOX_IMAGE to the
# tag the session should run.
_box_build() {
  local dockerfile
  dockerfile="$(_box_dockerfile)"
  [ -f "$dockerfile" ] || {
    echo "boxlib: base Dockerfile missing at $dockerfile (run 'make claude')" >&2
    return 1
  }
  if ! "$DOCKER_BIN" image inspect "$BOX_BASE_TAG" >/dev/null 2>&1; then
    echo "boxlib: building base image $BOX_BASE_TAG (first run may take a few minutes)..." >&2
    "$DOCKER_BIN" build -t "$BOX_BASE_TAG" -f "$dockerfile" "$(dirname "$dockerfile")" >&2 || return 1
  fi
  BOX_IMAGE="$BOX_BASE_TAG"
  # Optional per-project extension: ./container/Dockerfile, parallel to sandbox-escapes/.
  # Writing it is gated, so the box cannot be widened silently. Rebuild each launch;
  # Docker's layer cache makes an unchanged build cheap.
  if [ -f "./container/Dockerfile" ]; then
    local pid tag
    pid="$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)"
    tag="agents-box:proj-$pid"
    echo "boxlib: building per-project image $tag from ./container/Dockerfile..." >&2
    "$DOCKER_BIN" build -t "$tag" -f "./container/Dockerfile" "./container" >&2 || return 1
    BOX_IMAGE="$tag"
  fi
}

_box_prepare_reserved_mounts() {
  local workdir="$1"
  local name path
  BOX_RESERVED_MOUNTS=()
  BOX_CREATED_RESERVED_DIRS=()
  for name in sandbox-escapes container; do
    path="$workdir/$name"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
      mkdir "$path" || return 1
      BOX_CREATED_RESERVED_DIRS+=("$path")
    fi
    if [ ! -d "$path" ] || [ -L "$path" ]; then
      echo "boxlib: reserved project path must be a real directory: $path" >&2
      _box_cleanup_reserved_dirs
      return 1
    fi
    BOX_RESERVED_MOUNTS+=(-v "$path:$path:ro")
  done
}

_box_cleanup_reserved_dirs() {
  local path
  for path in "${BOX_CREATED_RESERVED_DIRS[@]:-}"; do
    rmdir "$path" 2>/dev/null || true
  done
  BOX_CREATED_RESERVED_DIRS=()
  BOX_RESERVED_MOUNTS=()
}

_box_secret_rel_matches() {
  local rel="$1"
  local glob base
  for glob in "${AGENTS_BOX_SECRET_GLOBS[@]}"; do
    case "$rel" in
      $glob) return 0 ;;
    esac
    base="${glob#**/}"
    if [ "$base" != "$glob" ]; then
      case "$rel" in
        $base) return 0 ;;
      esac
    fi
  done
  return 1
}

_box_add_unreadable_mount() {
  local path="$1"
  local kind="$2"
  local name target
  name="mask-${#BOX_POLICY_MOUNTS[@]}"
  target="$BOX_POLICY_TMP/$name"
  if [ "$kind" = "dir" ]; then
    mkdir "$target" || return 1
    chmod 0700 "$target" || return 1
  else
    : > "$target" || return 1
    chmod 0600 "$target" || return 1
  fi
  BOX_POLICY_MOUNTS+=(-v "$target:$path:ro")
}

_box_lock_policy_mounts() {
  [ -n "${BOX_POLICY_TMP:-}" ] || return 0
  find "$BOX_POLICY_TMP" -mindepth 1 -exec chmod 000 {} +
}

_box_policy_tmp_template() {
  local parent
  for parent in "${AGENTS_BOX_POLICY_TMPDIR:-}" /private/tmp "${TMPDIR:-}" /tmp; do
    [ -n "$parent" ] || continue
    [ -d "$parent" ] || continue
    [ -w "$parent" ] || continue
    printf '%s/agents-modes-box-policy.XXXXXX\n' "$parent"
    return 0
  done
  return 1
}

_box_prepare_policy_mounts() {
  local workdir="$1"
  local path rel entry policy_path kind
  BOX_POLICY_MOUNTS=()
  BOX_POLICY_TMP="$(mktemp -d "$(_box_policy_tmp_template)")" || return 1

  while IFS= read -r -d '' path; do
    rel="${path#$workdir/}"
    _box_secret_rel_matches "$rel" || continue
    if [ -L "$path" ]; then
      echo "boxlib: in-tree secret path must not be a symlink: $path" >&2
      _box_cleanup_policy_mounts
      return 1
    fi
    if [ -d "$path" ]; then
      _box_add_unreadable_mount "$path" dir || {
        _box_cleanup_policy_mounts
        return 1
      }
    else
      _box_add_unreadable_mount "$path" file || {
        _box_cleanup_policy_mounts
        return 1
      }
    fi
  done < <(find "$workdir" -mindepth 1 \( -type f -o -type d -o -type l \) -print0)

  for entry in "${AGENTS_BOX_FORBIDDEN_PROJECT_PATHS[@]}"; do
    policy_path="${entry%:*}"
    kind="${entry##*:}"
    case "$policy_path" in
      sandbox-escapes|container)
        continue
        ;;
    esac
    path="$workdir/$policy_path"
    [ -e "$path" ] || continue
    if [ -L "$path" ]; then
      echo "boxlib: forbidden project path must not be a symlink: $path" >&2
      _box_cleanup_policy_mounts
      return 1
    fi
    if [ "$kind" = "tree" ]; then
      [ -d "$path" ] || {
        echo "boxlib: forbidden project path should be a directory: $path" >&2
        _box_cleanup_policy_mounts
        return 1
      }
    else
      [ -f "$path" ] || {
        echo "boxlib: forbidden project path should be a file: $path" >&2
        _box_cleanup_policy_mounts
        return 1
      }
    fi
    BOX_POLICY_MOUNTS+=(-v "$path:$path:ro")
  done
}

_box_cleanup_policy_mounts() {
  if [ -n "${BOX_POLICY_TMP:-}" ]; then
    chmod -R u+rwx "$BOX_POLICY_TMP" 2>/dev/null || true
    rm -rf "$BOX_POLICY_TMP"
    unset BOX_POLICY_TMP
  fi
  BOX_POLICY_MOUNTS=()
}

box_start() {
  _box_load_policy || return 1
  _box_set_docker_config || return 1
  _box_ensure_docker || return 1
  local workdir="$PWD"
  _box_prepare_reserved_mounts "$workdir" || return 1
  _box_prepare_policy_mounts "$workdir" || {
    _box_cleanup_reserved_dirs
    return 1
  }
  _box_build || {
    _box_cleanup_policy_mounts
    _box_cleanup_reserved_dirs
    return 1
  }
  RUNBOX_CONTAINER="agents-box-$$-${RANDOM}"
  echo "boxlib: starting session container $RUNBOX_CONTAINER (workdir: $workdir)" >&2
  "$DOCKER_BIN" run -d --rm \
    --name "$RUNBOX_CONTAINER" \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --network bridge \
    -v "$workdir:$workdir" \
    "${BOX_RESERVED_MOUNTS[@]}" \
    "${BOX_POLICY_MOUNTS[@]}" \
    -w "$workdir" \
    "$BOX_IMAGE" >/dev/null || {
    echo "boxlib: failed to start session container" >&2
    _box_cleanup_policy_mounts
    _box_cleanup_reserved_dirs
    return 1
  }
  _box_lock_policy_mounts || {
    echo "boxlib: failed to lock policy-mask mounts" >&2
    "$DOCKER_BIN" rm -f "$RUNBOX_CONTAINER" >/dev/null 2>&1 || true
    _box_cleanup_policy_mounts
    _box_cleanup_reserved_dirs
    return 1
  }
  export RUNBOX_CONTAINER
}

box_stop() {
  if [ -n "${RUNBOX_CONTAINER:-}" ]; then
    "${DOCKER_BIN:-docker}" rm -f "$RUNBOX_CONTAINER" >/dev/null 2>&1 || true
    unset RUNBOX_CONTAINER
  fi
  _box_cleanup_policy_mounts
  _box_cleanup_reserved_dirs
}
