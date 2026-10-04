#!/usr/bin/env bash
# entrypoint.sh — prépare le home de dev (Claude Code, git, my-claude-config), puis lance
# Remote Control supervisé dans tmux. Avec des arguments, exécute la commande à la place.
# shellcheck disable=SC2016  # helpers git : $ développé par git à l'appel, pas ici
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
