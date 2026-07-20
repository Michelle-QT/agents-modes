# Base image for the container-exec substrate (see the `runbox auto` entry in README.md).
#
# Mode-agnostic tooling base. A mode launcher (currently claude-research) runs a
# locked, workdir-only container from this image and the host-side `runbox` wrapper
# `docker exec`s into it. The image is the security boundary: full internet, but the
# project working directory (bind-mounted) is the container's entire filesystem world.
#
# Projects extend it with their own ./container/Dockerfile starting `FROM agents-box:base`;
# that per-project image is built on top and used in place of the base for the session.
#
# The container runs as the host UID (see boxlib.sh), so it does not install packages
# at runtime; add durable tools by editing a tracked Dockerfile, keeping provenance in
# git and the container disposable.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      wget \
      git \
      openssh-client \
      python3 \
      python3-pip \
      python3-venv \
      poppler-utils \
      pandoc \
      jq \
      unzip \
      less \
 && rm -rf /var/lib/apt/lists/*

# Keep the container alive so the launcher can `docker exec` into it for the session;
# the launcher force-removes it on exit.
CMD ["sleep", "infinity"]
