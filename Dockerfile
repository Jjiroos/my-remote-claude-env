# syntax=docker/dockerfile:1
# Image de dev pour Claude Code en Remote Control : toolchains Node, Python, Java, Go, Rust.
FROM ubuntu:26.04

ARG TARGETARCH
ARG NODE_MAJOR=24
ARG GO_VERSION=1.27.1

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git jq ripgrep shellcheck tmux sudo xz-utils unzip less procps \
      build-essential pkg-config libssl-dev python3 python3-venv \
      openjdk-25-jdk-headless openjdk-21-jdk-headless maven \
    && update-alternatives --set java "/usr/lib/jvm/java-25-openjdk-${TARGETARCH}/bin/java" \
    && update-alternatives --set javac "/usr/lib/jvm/java-25-openjdk-${TARGETARCH}/bin/javac" \
    && rm -rf /var/lib/apt/lists/*
ENV JAVA_HOME=/usr/lib/jvm/java-25-openjdk-${TARGETARCH} \
    JAVA21_HOME=/usr/lib/jvm/java-21-openjdk-${TARGETARCH}

# Docker CLI (compose, buildx) et gh depuis leurs dépôts officiels : ceux d'Ubuntu sont en retard.
RUN . /etc/os-release \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli.gpg \
    && echo "deb [arch=${TARGETARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
         > /etc/apt/sources.list.d/docker.list \
    && echo "deb [arch=${TARGETARCH} signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends \
         docker-ce-cli docker-compose-plugin docker-buildx-plugin gh \
    && rm -rf /var/lib/apt/lists/*

# Node LTS : dernière version de la branche NODE_MAJOR, somme SHA-256 vérifiée.
RUN cd /tmp \
    && base="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x" \
    && curl -fsSLO "${base}/SHASUMS256.txt" \
    && file="$(awk -v suffix="linux-${TARGETARCH/amd64/x64}.tar.xz" '$2 ~ suffix"$" {print $2}' SHASUMS256.txt)" \
    && curl -fsSLO "${base}/${file}" \
    && grep " ${file}\$" SHASUMS256.txt | sha256sum -c - \
    && tar -xJf "${file}" -C /usr/local --strip-components=1 --exclude='*.md' --exclude=LICENSE \
    && rm -f "${file}" SHASUMS256.txt

# Go : archive officielle, somme SHA-256 vérifiée.
RUN cd /tmp \
    && file="go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" \
    && sum="$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all' | jq -r --arg f "$file" '.[].files[] | select(.filename == $f) | .sha256')" \
    && curl -fsSLO "https://go.dev/dl/${file}" \
    && echo "${sum}  ${file}" | sha256sum -c - \
    && tar -xzf "${file}" -C /usr/local \
    && rm -f "${file}"

RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh

# L'image Ubuntu fournit déjà ubuntu (UID 1000) : renommé dev, aligné sur pibot de l'hôte.
RUN usermod -l dev -d /home/dev -m ubuntu \
    && groupmod -n dev ubuntu \
    && echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev \
    && install -d -o dev -g dev /workspace /opt/rust

ENV RUSTUP_HOME=/opt/rust/rustup \
    CARGO_HOME=/opt/rust/cargo \
    PATH=/home/dev/.local/bin:/opt/rust/cargo/bin:/usr/local/go/bin:/home/dev/go/bin:${PATH}

USER dev
WORKDIR /home/dev
RUN curl --proto '=https' -fsSL https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal -c clippy -c rustfmt
RUN curl -fsSL https://claude.ai/install.sh | bash
WORKDIR /workspace
ENV RC_NAME=piserv-dev \
    RESTART_DELAY=10 \
    CLAUDE_CONFIG_REPO=https://github.com/Jjiroos/my-claude-config.git \
    CLAUDE_CONFIG_CHECKOUT=/home/dev/my-claude-config \
    FORGEJO_USER=claude-bot \
    GIT_USER_NAME="Claude (piserv-dev)" \
    GIT_USER_EMAIL=claude-bot@localhost
COPY --chmod=0755 entrypoint.sh supervisor.sh /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
