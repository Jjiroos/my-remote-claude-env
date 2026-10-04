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

sections=("$@")
((${#sections[@]})) || sections=(toolchains docker ports guards supervisor forges)
for section in "${sections[@]}"; do
  "check_$section"
done
