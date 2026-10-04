#!/usr/bin/env bash
# smoke-test.sh — vérifie my-claude-env de bout en bout, depuis l'hôte.
# Usage : scripts/smoke-test.sh [toolchains|docker|ports|guards|supervisor|forges]...
# Sans argument, lance toutes les sections. S'arrête au premier échec.
# shellcheck disable=SC2016  # commandes exécutées dans le conteneur : $ volontairement non développé ici
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

check_docker() {
  in_claude 'docker run --rm hello-world' | grep -q 'Hello from Docker' || fail "docker run via dind"
  local inner
  inner="$(in_claude 'docker ps -a --format "{{.Names}}"')"
  while read -r name; do
    [[ -z "$name" ]] && continue
    grep -qxF "$name" <<<"$inner" && fail "le conteneur de l'hôte $name est visible depuis claude"
  done < <(docker ps -a --format '{{.Names}}')
  # 2375 = 0x0947 ; le démon ne doit écouter que sur 127.0.0.1 (0100007F), jamais sur 0.0.0.0.
  in_claude 'grep -qE "^ *[0-9]+: 0100007F:0947 " /proc/net/tcp' || fail "démon absent de 127.0.0.1:2375"
  in_claude 'grep -qE "^ *[0-9]+: 00000000:0947 " /proc/net/tcp' && fail "démon Docker à l'écoute sur 0.0.0.0:2375"
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
  in_claude 'pkill -f "[c]laude remote-control" || true'  # [c] : le motif ne tue pas ce shell
  wait_for_more_starts "$before" || fail "la boucle n'a pas relancé claude remote-control"
  docker compose restart claude >/dev/null
  for _ in {1..30}; do in_claude 'tmux has-session -t claude' 2>/dev/null && break; sleep 1; done
  in_claude 'tmux has-session -t claude' || fail "tmux absent après redémarrage du conteneur"
  in_claude 'test -d ~/my-claude-config/.git' || fail "my-claude-config absent après redémarrage"
  ok "supervision et redémarrage"
}

sections=("$@")
((${#sections[@]})) || sections=(toolchains docker ports guards supervisor forges)
for section in "${sections[@]}"; do
  "check_$section"
done
