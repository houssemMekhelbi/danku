# Shared base for the three harness images. Build: podman build -f base.Containerfile -t localhost/ai-base:1 .
FROM docker.io/library/node:24-trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git openssh-client curl ripgrep fd-find procps jq less netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*
# Runs as the host user's uid (--userns=keep-id). HOME is a bind mount from $AI_STATE/<harness>/home.
RUN userdel -r node 2>/dev/null || true; useradd -m -u 1000 agent
ENV HOME=/home/agent NODE_USE_ENV_PROXY=1 DISABLE_AUTOUPDATER=1 CI=1
USER agent
WORKDIR /workspace
