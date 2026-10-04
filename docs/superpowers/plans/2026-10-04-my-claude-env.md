# my-claude-env Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un environnement Docker Compose sur piserv où Claude Code tourne en permanence en mode serveur Remote Control, avec toolchains complètes et un démon Docker isolé de la prod.

**Architecture:** Deux services. `dind` (`docker:dind`, privileged) porte l'espace réseau, le démon sur `tcp://127.0.0.1:2375` et la plage de ports `127.0.0.1:4100-4119`. `claude` (image Ubuntu 26.04 construite ici) partage cet espace réseau (`network_mode: service:dind`) et lance `claude remote-control` dans une boucle de supervision, elle-même dans tmux.

**Tech Stack:** Docker Compose v5, `docker:dind`, Ubuntu 26.04, bash, tmux, Claude Code (installeur natif), Node 24, uv, OpenJDK 25/21, Maven, Go 1.27.1, rustup.

**Spec:** `docs/superpowers/specs/2026-10-04-my-claude-env-design.md`

## Global Constraints

- Hôte `piserv` = prod. Aucune commande ne touche aux conteneurs, réseaux ou volumes `mycollectbuddy-*` et `forgejo*`. Toutes les commandes compose se lancent depuis `~/workspace/my-claude-env`, projet compose `my-claude-env`.
- Aucun bind mount de l'hôte, aucun socket Docker de l'hôte.
- Ports publiés uniquement sur `127.0.0.1`, plage par défaut `4100-4119`.
- Base `ubuntu:26.04` ; utilisateur `dev`, UID et GID 1000.
- Java 25 par défaut, Java 21 présent.
- Forgejo par son URL publique, lue dans `FORGEJO_URL` (`.env`). Cette URL n'apparaît dans aucun fichier versionné, car le dépôt `my-remote-claude-env` est public. Jamais par le réseau `forgejo_forgejo-net`.
- `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` et `ANTHROPIC_BASE_URL` sont interdits dans le conteneur.
- Commits : Conventional Commits en français, sujet ≤ 72 caractères, corps de 2 à 5 lignes, sans trailer d'attribution. Branche `feat/environnement`. Pas de push.

## Review Focus

1. **Variable d'API Anthropic présente dans `.env`.** L'entrypoint doit refuser de démarrer avec un message clair, plutôt qu'un Remote Control qui échoue en silence. Le test `guards` est en tâche 2.
2. **Réseau absent au démarrage (clone de my-claude-config impossible).** Le conteneur doit démarrer quand même, avec un avertissement. Le test `guards` est en tâche 2.
3. **Port de dev publié sur le LAN par erreur.** Il doit rester inaccessible par l'IP LAN. Le test `ports` est en tâche 2.
4. **Redémarrage du conteneur ou de l'hôte.** tmux et la boucle doivent revenir seuls, et la config ne doit pas être reclonée. Le test `supervisor` est en tâche 2 (`docker compose restart`).
5. **Dépôt public utilisé pour tester une forge.** `ls-remote` réussirait sans token. Le README et `.env.example` exigent un dépôt **privé**, et le test `forges` est en tâche 3.

---

### Task 1: Image `claude` et vérification des toolchains

**Files:**
- Create: `Dockerfile`, `.gitignore`, `.env.example`, `scripts/smoke-test.sh`

**Interfaces:**
- Produces: l'image `my-claude-env:latest` (utilisateur `dev`, `PATH` avec `/home/dev/.local/bin:/opt/rust/cargo/bin:/usr/local/go/bin:/home/dev/go/bin`), et `scripts/smoke-test.sh [section...]` avec les fonctions `fail`, `ok`, `warn`, `run_image <cmd>`, `in_claude <cmd>` et la section `toolchains`.

- [ ] **Step 1: Créer la branche**

```bash
cd ~/workspace/my-claude-env && git switch -c feat/environnement
```

- [ ] **Step 2: Écrire le test (section `toolchains`)**

`scripts/smoke-test.sh` :

```bash
#!/usr/bin/env bash
# smoke-test.sh — vérifie my-claude-env de bout en bout, depuis l'hôte.
# Usage : scripts/smoke-test.sh [toolchains|docker|ports|guards|supervisor|forges]...
# Sans argument, lance toutes les sections. S'arrête au premier échec.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=my-claude-env:latest

fail() { echo "✗ $*" >&2; exit 1; }
ok() { echo "✓ $*"; }
warn() { echo "⚠ $*"; }
run_image() { docker run --rm --entrypoint bash "$IMAGE" -c "$1"; }
in_claude() { docker compose exec -T claude bash -c "$1"; }

check_toolchains() {
  run_image 'test "$(whoami)" = dev && test "$(id -u)" = 1000' || fail "utilisateur dev (UID 1000) absent"
  run_image 'node --version | grep -q "^v24\." && npx --version' >/dev/null || fail "Node 24 / npx"
  run_image 'uv run python --version' >/dev/null || fail "uv / python"
  run_image 'java -version 2>&1 | grep -q "version \"25"' || fail "Java 25 n'est pas le défaut"
  run_image 'ls /usr/lib/jvm/java-21-openjdk-*/bin/java' >/dev/null || fail "JDK 21 absent"
  run_image 'mvn -v && go version && cargo --version && claude --version' >/dev/null \
    || fail "mvn / go / cargo / claude"
  run_image 'docker --version && docker compose version && gh --version && tmux -V && rg --version && shellcheck --version && jq --version' >/dev/null \
    || fail "outils CLI"
  run_image 'sudo -n true' || fail "sudo sans mot de passe pour dev"
  ok "toolchains"
}

sections=("$@")
((${#sections[@]})) || sections=(toolchains docker ports guards supervisor forges)
for section in "${sections[@]}"; do
  "check_$section"
done
```

```bash
chmod +x scripts/smoke-test.sh
```

- [ ] **Step 3: Vérifier que le test échoue**

Run: `scripts/smoke-test.sh toolchains`
Expected: FAIL, avec `Unable to find image 'my-claude-env:latest'` puis `✗ utilisateur dev (UID 1000) absent`.

- [ ] **Step 4: Écrire `.gitignore` et `.env.example`**

`.gitignore` :

```
.env
```

`.env.example` :

```bash
# Copier en .env puis chmod 600 .env. Une ligne commentée garde la valeur par défaut
# de l'image ou de compose.yaml ; ne pas la décommenter vide, elle écraserait ce défaut.

# Forges : tokens dédiés et révocables (voir README).
# FORGEJO_URL : URL publique du Forgejo (son ROOT_URL), obligatoire pour y accéder.
FORGEJO_URL=
GH_TOKEN=
FORGEJO_TOKEN=
# FORGEJO_USER=claude-bot
# GIT_USER_NAME=Claude (piserv-dev)
# GIT_USER_EMAIL=claude-bot@localhost

# Smoke test des forges : dépôts PRIVÉS (propriétaire/nom), sinon le test passe sans token.
SMOKE_FORGEJO_REPO=
SMOKE_GITHUB_REPO=

# Remote Control
# RC_NAME=piserv-dev
# RESTART_DELAY=10

# Ressources et ports (interpolés par compose.yaml)
# PORT_RANGE=4100-4119
# CLAUDE_MEM=3g
# CLAUDE_CPUS=3
# DIND_MEM=2g
```

- [ ] **Step 5: Écrire le `Dockerfile` (sans ENTRYPOINT, ajouté en tâche 2)**

```dockerfile
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
```

- [ ] **Step 6: Construire l'image**

Run: `docker build -t my-claude-env:latest .` (en tâche de fond, plusieurs minutes sur le Pi)
Expected: build terminé sans erreur. Si un `update-alternatives` échoue, lister `/usr/lib/jvm` dans l'image et corriger le chemin.

- [ ] **Step 7: Vérifier que le test passe**

Run: `scripts/smoke-test.sh toolchains && shellcheck scripts/smoke-test.sh`
Expected: `✓ toolchains`, shellcheck muet.

- [ ] **Step 8: Commit**

```bash
git add Dockerfile .gitignore .env.example scripts/smoke-test.sh
git commit -m "feat: image Ubuntu 26.04 avec les toolchains de dev" \
  -m "Node 24, uv, Java 25 et 21, Maven, Go, Rust, Docker CLI, gh et Claude Code
sous l'utilisateur dev (UID 1000). Le smoke test vérifie chaque outil."
```

---

### Task 2: Compose, démon isolé, entrypoint et supervision Remote Control

**Files:**
- Create: `compose.yaml`, `entrypoint.sh`, `supervisor.sh`
- Modify: `Dockerfile` (ENV par défaut, COPY et ENTRYPOINT en fin de fichier), `scripts/smoke-test.sh` (sections `docker`, `ports`, `guards`, `supervisor`)

**Interfaces:**
- Consumes: l'image de la tâche 1 et les fonctions `fail`, `ok`, `warn`, `run_image`, `in_claude` du smoke test.
- Produces: les services compose `dind` et `claude`, la session tmux `claude`, le journal `/home/dev/supervisor.log` (une ligne `<date ISO> démarrage` par lancement), et les variables lues par l'entrypoint : `RC_NAME`, `RESTART_DELAY`, `CLAUDE_CONFIG_REPO`, `CLAUDE_CONFIG_CHECKOUT`, `FORGEJO_URL`, `FORGEJO_USER`, `GIT_USER_NAME`, `GIT_USER_EMAIL`, `GH_TOKEN`, `FORGEJO_TOKEN`.

- [ ] **Step 1: Écrire les tests (sections `docker`, `ports`, `guards`, `supervisor`)**

Ajouter dans `scripts/smoke-test.sh`, après `check_toolchains` :

```bash
check_docker() {
  in_claude 'docker run --rm hello-world' | grep -q 'Hello from Docker' || fail "docker run via dind"
  local inner
  inner="$(in_claude 'docker ps -a --format "{{.Names}}"')"
  while read -r name; do
    [[ -z "$name" ]] && continue
    grep -qxF "$name" <<<"$inner" && fail "le conteneur de l'hôte $name est visible depuis claude"
  done < <(docker ps -a --format '{{.Names}}')
  ok "docker isolé"
}

check_ports() {
  in_claude 'setsid nohup python3 -m http.server 4100 >/tmp/smoke-http.log 2>&1 & echo $! >/tmp/smoke-http.pid'
  local up=false
  for _ in {1..10}; do
    curl -fs --max-time 2 -o /dev/null http://127.0.0.1:4100 && { up=true; break; }
    sleep 1
  done
  local lan_ip
  lan_ip="$(hostname -I | awk '{print $1}')"
  local on_lan=false
  curl -fs --max-time 3 -o /dev/null "http://${lan_ip}:4100" && on_lan=true
  in_claude 'kill "$(cat /tmp/smoke-http.pid)"'
  $up || fail "port 4100 injoignable sur 127.0.0.1 depuis l'hôte"
  $on_lan && fail "port 4100 exposé sur le LAN (${lan_ip})"
  ok "ports en local seulement"
}

check_guards() {
  local out
  if out="$(docker compose run --rm --no-deps -e ANTHROPIC_API_KEY=interdit claude true 2>&1)"; then
    fail "l'entrypoint démarre malgré ANTHROPIC_API_KEY"
  fi
  grep -q 'ANTHROPIC_API_KEY' <<<"$out" || fail "message d'erreur sans le nom de la variable : $out"
  out="$(docker compose run --rm --no-deps \
    -e CLAUDE_CONFIG_REPO=https://127.0.0.1:9/absent.git -e CLAUDE_CONFIG_CHECKOUT=/tmp/cfg \
    claude true 2>&1)" || fail "le démarrage échoue quand my-claude-config est injoignable : $out"
  grep -q 'clone' <<<"$out" || fail "pas d'avertissement de clone : $out"
  ok "garde-fous de l'entrypoint"
}

count_starts() { in_claude 'grep -c " démarrage$" ~/supervisor.log || true'; }

wait_for_more_starts() {
  local before="$1"
  for _ in {1..40}; do
    (( $(count_starts) > before )) && return 0
    sleep 1
  done
  return 1
}

check_supervisor() {
  in_claude 'tmux has-session -t claude' || fail "session tmux claude absente"
  local before
  before="$(count_starts)"
  in_claude 'pkill -f "claude remote-control" || true'
  wait_for_more_starts "$before" || fail "la boucle n'a pas relancé claude remote-control"
  docker compose restart claude >/dev/null
  for _ in {1..30}; do in_claude 'tmux has-session -t claude' 2>/dev/null && break; sleep 1; done
  in_claude 'tmux has-session -t claude' || fail "tmux absent après redémarrage du conteneur"
  in_claude 'test -d ~/my-claude-config/.git' || fail "my-claude-config absent après redémarrage"
  ok "supervision et redémarrage"
}
```

- [ ] **Step 2: Vérifier que les tests échouent**

Run: `scripts/smoke-test.sh docker`
Expected: FAIL, `no configuration file provided: not found` puis `✗ docker run via dind`.

- [ ] **Step 3: Écrire `compose.yaml`**

```yaml
# my-claude-env : Claude Code en Remote Control (claude) et démon Docker isolé (dind).
# claude partage l'espace réseau de dind : le démon, les serveurs de dev natifs et les
# ports publiés par les conteneurs internes sont tous sur localhost.
name: my-claude-env

services:
  dind:
    image: docker:dind
    privileged: true
    hostname: claude-env
    restart: unless-stopped
    environment:
      DOCKER_TLS_CERTDIR: ""
    # Sans TLS, mais seulement sur la boucle locale de l'espace réseau partagé avec claude.
    command: ["--host=tcp://127.0.0.1:2375"]
    volumes:
      - dind-data:/var/lib/docker
    ports:
      - "127.0.0.1:${PORT_RANGE:-4100-4119}:${PORT_RANGE:-4100-4119}"
    mem_limit: ${DIND_MEM:-2g}
    healthcheck:
      test: ["CMD", "docker", "-H", "tcp://127.0.0.1:2375", "info"]
      interval: 10s
      timeout: 5s
      retries: 12

  claude:
    build: .
    image: my-claude-env:latest
    network_mode: service:dind
    init: true
    restart: unless-stopped
    depends_on:
      dind:
        condition: service_healthy
        restart: true
    env_file:
      - path: .env
        required: false
    environment:
      DOCKER_HOST: tcp://127.0.0.1:2375
    volumes:
      - home:/home/dev
      - workspace:/workspace
    mem_limit: ${CLAUDE_MEM:-3g}
    cpus: ${CLAUDE_CPUS:-3}

volumes:
  home:
  workspace:
  dind-data:
```

- [ ] **Step 4: Écrire `supervisor.sh`**

```bash
#!/usr/bin/env bash
# supervisor.sh — garde claude remote-control en vie : le serveur sort après ~10 min sans
# réseau ou en cas d'erreur ; une relance dans /workspace récupère ses sessions (~4 h).
set -uo pipefail

log="$HOME/supervisor.log"
cd /workspace

while true; do
  printf '%s démarrage\n' "$(date -Is)" >>"$log"
  claude remote-control --name "$RC_NAME" --permission-mode bypassPermissions
  code=$?
  printf '%s sortie (code %d), relance dans %ss\n' "$(date -Is)" "$code" "$RESTART_DELAY" >>"$log"
  sleep "$RESTART_DELAY"
done
```

- [ ] **Step 5: Écrire `entrypoint.sh`**

```bash
#!/usr/bin/env bash
# entrypoint.sh — prépare le home de dev (Claude Code, git, my-claude-config), puis lance
# Remote Control supervisé dans tmux. Avec des arguments, exécute la commande à la place.
set -euo pipefail

for var in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL; do
  if [[ -n "${!var:-}" ]]; then
    echo "entrypoint : $var est défini ; Remote Control exige l'auth claude.ai, retire-le de .env" >&2
    exit 1
  fi
done

if [[ ! -x "$HOME/.local/bin/claude" ]]; then
  echo "entrypoint : Claude Code absent du volume home, installation"
  curl -fsSL https://claude.ai/install.sh | bash
fi

git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"
git config --global init.defaultBranch main
# Les tokens restent dans l'environnement : le helper les lit à chaque appel de git.
git config --global --unset-all credential.https://github.com.helper || true
if [[ -n "${GH_TOKEN:-}" ]]; then
  git config --global credential.https://github.com.helper \
    '!f() { [ "$1" = get ] && printf "username=x-access-token\npassword=%s\n" "$GH_TOKEN"; }; f'
fi
forgejo_url="${FORGEJO_URL:-}"
forgejo_url="${forgejo_url%/}"
if [[ -n "$forgejo_url" ]]; then
  git config --global --unset-all "credential.${forgejo_url}.helper" || true
  if [[ -n "${FORGEJO_TOKEN:-}" ]]; then
    git config --global "credential.${forgejo_url}.helper" \
      '!f() { [ "$1" = get ] && printf "username=%s\npassword=%s\n" "$FORGEJO_USER" "$FORGEJO_TOKEN"; }; f'
  fi
elif [[ -n "${FORGEJO_TOKEN:-}" ]]; then
  echo "entrypoint : FORGEJO_TOKEN sans FORGEJO_URL, accès Forgejo non configuré" >&2
fi

if [[ -d "$CLAUDE_CONFIG_CHECKOUT/.git" ]]; then
  git -C "$CLAUDE_CONFIG_CHECKOUT" pull --ff-only -q \
    || echo "entrypoint : pull de my-claude-config impossible, version locale conservée" >&2
else
  git clone -q "$CLAUDE_CONFIG_REPO" "$CLAUDE_CONFIG_CHECKOUT" \
    || echo "entrypoint : clone de my-claude-config impossible, démarrage sans cette config" >&2
fi
if [[ -x "$CLAUDE_CONFIG_CHECKOUT/install.sh" ]]; then
  "$CLAUDE_CONFIG_CHECKOUT/install.sh" >"$HOME/install-config.log" 2>&1 \
    || echo "entrypoint : install.sh de my-claude-config en échec, voir ~/install-config.log" >&2
fi

if (($#)); then
  exec "$@"
fi

tmux new-session -d -s claude /usr/local/bin/supervisor.sh
echo "entrypoint : Remote Control supervisé dans tmux (docker compose exec claude tmux attach -t claude)"
while tmux has-session -t claude 2>/dev/null; do
  sleep 10
done
echo "entrypoint : session tmux terminée" >&2
exit 1
```

- [ ] **Step 6: Ajouter les défauts et l'entrypoint au `Dockerfile`**

À la fin du `Dockerfile`, après `WORKDIR /workspace` :

```dockerfile
ENV RC_NAME=piserv-dev \
    RESTART_DELAY=10 \
    CLAUDE_CONFIG_REPO=https://github.com/Jjiroos/my-claude-config.git \
    CLAUDE_CONFIG_CHECKOUT=/home/dev/my-claude-config \
    FORGEJO_USER=claude-bot \
    GIT_USER_NAME="Claude (piserv-dev)" \
    GIT_USER_EMAIL=claude-bot@localhost
COPY --chmod=0755 entrypoint.sh supervisor.sh /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

```bash
chmod +x entrypoint.sh supervisor.sh
```

- [ ] **Step 7: Construire et démarrer**

Run: `docker compose up -d --build && docker compose ps && docker compose logs claude | tail -20`
Expected: `dind` est `healthy`, `claude` est `running`, et les logs montrent `entrypoint : Remote Control supervisé dans tmux`. Avant `/login`, `~/supervisor.log` enchaîne normalement des sorties en erreur toutes les 10 s.

- [ ] **Step 8: Vérifier le nom d'hôte vu par Claude**

Run: `docker compose exec claude hostname`
Expected: `claude-env`, et pas `piserv`, pour que la règle « piserv = prod » du CLAUDE.md ne s'applique pas dans le conteneur. Si la valeur diffère, consigner le nom réel dans le README (tâche 4) au lieu d'ajouter une option.

- [ ] **Step 9: Vérifier que les tests passent**

Run: `scripts/smoke-test.sh toolchains docker ports guards supervisor && shellcheck entrypoint.sh supervisor.sh scripts/smoke-test.sh`
Expected: cinq lignes `✓`, shellcheck muet.

- [ ] **Step 10: Commit**

```bash
git add compose.yaml entrypoint.sh supervisor.sh Dockerfile scripts/smoke-test.sh
git commit -m "feat: compose claude + dind et Remote Control supervisé" \
  -m "dind isole le démon Docker de la prod et porte la plage de ports locale.
L'entrypoint prépare git et my-claude-config, puis lance la boucle
claude remote-control dans tmux ; il refuse toute auth par clé API."
```

---

### Task 3: Accès aux forges avec tokens dédiés

**Files:**
- Modify: `scripts/smoke-test.sh` (section `forges`)

**Interfaces:**
- Consumes: le credential helper écrit par `entrypoint.sh` (tâche 2), et les variables `GH_TOKEN`, `FORGEJO_TOKEN`, `FORGEJO_URL`, `SMOKE_GITHUB_REPO`, `SMOKE_FORGEJO_REPO` venues de `.env`.
- Produces: la section `forges` du smoke test.

- [ ] **Step 1: Écrire le test**

Ajouter dans `scripts/smoke-test.sh` :

```bash
check_forges() {
  if ! in_claude '[[ -n "${GH_TOKEN:-}" && -n "${SMOKE_GITHUB_REPO:-}" ]]'; then
    warn "GitHub non testé : GH_TOKEN ou SMOKE_GITHUB_REPO absent de .env"
  else
    in_claude 'GIT_TERMINAL_PROMPT=0 git ls-remote "https://github.com/${SMOKE_GITHUB_REPO}.git" HEAD' >/dev/null \
      || fail "ls-remote GitHub refusé"
    in_claude 'gh api user --jq .login' >/dev/null || fail "gh ne s'authentifie pas avec GH_TOKEN"
    ok "GitHub"
  fi
  if ! in_claude '[[ -n "${FORGEJO_URL:-}" && -n "${FORGEJO_TOKEN:-}" && -n "${SMOKE_FORGEJO_REPO:-}" ]]'; then
    warn "Forgejo non testé : FORGEJO_URL, FORGEJO_TOKEN ou SMOKE_FORGEJO_REPO absent de .env"
  else
    in_claude 'GIT_TERMINAL_PROMPT=0 git ls-remote "${FORGEJO_URL%/}/${SMOKE_FORGEJO_REPO}.git" HEAD' >/dev/null \
      || fail "ls-remote Forgejo refusé"
    ok "Forgejo"
  fi
}
```

- [ ] **Step 2: Vérifier que la section avertit sans `.env`**

Run: `scripts/smoke-test.sh forges`
Expected: deux lignes `⚠`, car `.env` n'existe pas encore.

- [ ] **Step 3: Faire créer les tokens (geste humain)**

Demander à l'utilisateur de :
1. Créer sur Forgejo l'utilisateur `claude-bot`, l'ajouter comme collaborateur en écriture aux dépôts voulus, puis générer un token avec le scope `write:repository`.
2. Créer sur GitHub un fine-grained PAT limité aux dépôts voulus, avec Contents et Pull requests en lecture/écriture.
3. `cp .env.example .env && chmod 600 .env`, renseigner `FORGEJO_URL` (le `ROOT_URL` de Forgejo), `GH_TOKEN`, `FORGEJO_TOKEN`, `SMOKE_GITHUB_REPO` et `SMOKE_FORGEJO_REPO` (dépôts **privés**).

Si l'utilisateur reporte cette étape, passer à la tâche 4 et marquer les forges « non vérifié ».

- [ ] **Step 4: Recréer le conteneur et vérifier**

Run: `docker compose up -d && docker compose exec -T claude bash -c 'curl -fs -o /dev/null -w "%{http_code}\n" "$FORGEJO_URL/api/v1/version"'`
Expected: `200`, ce qui prouve que Forgejo est joignable depuis le conteneur par son URL publique.

Run: `scripts/smoke-test.sh forges && shellcheck scripts/smoke-test.sh`
Expected: `✓ GitHub` et `✓ Forgejo`.

- [ ] **Step 5: Commit**

```bash
git add scripts/smoke-test.sh
git commit -m "test: vérifie l'accès aux forges avec les tokens dédiés" \
  -m "ls-remote sur un dépôt privé de chaque forge, et gh authentifié par GH_TOKEN.
Sans token, la section avertit au lieu d'échouer."
```

---

### Task 4: README et premier login

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: tout ce qui précède.

- [ ] **Step 1: Écrire `README.md`**

````markdown
# my-claude-env

Claude Code tourne en permanence sur piserv, dans un conteneur, et se pilote depuis
[claude.ai/code](https://claude.ai/code) ou l'app mobile (Remote Control). Il a les mains
libres dans le conteneur (`bypassPermissions`, `sudo`) et aucun accès à la prod : démon
Docker séparé (`dind`), aucun montage de l'hôte, ports publiés en local seulement.

Design : [spec](docs/superpowers/specs/2026-10-04-my-claude-env-design.md).

## Installer

```bash
cp .env.example .env && chmod 600 .env   # puis renseigner les tokens (voir Forges)
docker compose up -d --build
scripts/smoke-test.sh
```

## Premier login (une fois)

Remote Control demande un terminal la première fois :

```bash
docker compose exec claude tmux attach -t claude
```

Dans tmux : `/login` avec le compte claude.ai (abonnement requis, pas de clé API), puis
accepter « Trust /workspace? », « Enable Remote Control? » et l'avertissement du mode
bypass. Détacher avec `Ctrl-b d`. La session `piserv-dev` apparaît alors dans claude.ai/code.

## Usage

- Les projets vivent dans le volume `workspace`, sous `/workspace`. Une session part de
  `/workspace` et fait `cd` vers le projet voulu.
- Un serveur de dev, natif ou lancé par `docker compose` dans le conteneur, se publie sur
  un port de `4100-4119` et se consulte sur l'hôte à `127.0.0.1:<port>`, par tunnel SSH
  par exemple : `ssh -L 4100:127.0.0.1:4100 piserv`.
- `~/supervisor.log` journalise chaque relance de `claude remote-control`.
- La config Claude vient de [my-claude-config](https://github.com/Jjiroos/my-claude-config),
  mise à jour par `git pull` à chaque démarrage du conteneur.

## Forges

Tokens dédiés, révocables sans toucher aux accès personnels :

| Variable | Origine | Droits |
|---|---|---|
| `FORGEJO_TOKEN` | utilisateur Forgejo `claude-bot`, collaborateur des dépôts voulus | `write:repository` |
| `GH_TOKEN` | fine-grained PAT GitHub limité aux dépôts voulus | Contents et Pull requests en lecture/écriture |

`SMOKE_FORGEJO_REPO` et `SMOKE_GITHUB_REPO` désignent des dépôts **privés**, sinon le smoke
test passe sans token. Pour faire tourner un token, éditer `.env`, puis lancer
`docker compose up -d`.

## Mettre à jour l'image

```bash
docker compose build --pull && docker compose up -d
```

Claude Code se met à jour seul dans le volume `home`, et les autres toolchains suivent
l'image. Go est fixé par `GO_VERSION` dans le `Dockerfile`.

## Ressources

Plafonds dans `.env` : `CLAUDE_MEM` (3g), `CLAUDE_CPUS` (3), `DIND_MEM` (2g). La prod de
piserv garde sa marge sur les 8 Go du Pi.
````

- [ ] **Step 2: Premier login (geste humain)**

Demander à l'utilisateur de suivre « Premier login », puis d'ouvrir la session `piserv-dev` depuis claude.ai/code et d'y envoyer `hostname && claude --version`.
Expected: `claude-env` (ou le nom consigné en tâche 2) et la version. Tant que l'utilisateur ne l'a pas confirmé, ce point est **non vérifié**.

- [ ] **Step 3: Rejouer la suite complète**

Run: `scripts/smoke-test.sh`
Expected: toutes les sections passent (`forges` peut avertir si les tokens sont reportés). La section `supervisor`, une fois le login fait, prouve la relance d'un vrai serveur Remote Control.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: README d'installation, premier login et usage" \
  -m "Décrit le seul geste manuel (login et confirmations Remote Control), l'accès
aux apps par la plage de ports locale et la gestion des tokens de forge."
```
