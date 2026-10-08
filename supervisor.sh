#!/usr/bin/env bash
# supervisor.sh — garde claude remote-control en vie : le serveur sort après ~10 min sans
# réseau ou en cas d'erreur ; une relance dans /workspace récupère ses sessions (~4 h).
set -uo pipefail

log="$HOME/supervisor.log"
# Un Ctrl-c dans tmux arrête claude ou le sleep, jamais la boucle : sans ce trap, bash
# sort avec un enfant tué par SIGINT, ce qui ferme tmux et redémarre le conteneur.
trap ':' INT
cd /workspace || exit 1

while true; do
  printf '%s démarrage\n' "$(date -Is)" >>"$log"
  claude remote-control --name "$RC_NAME" --permission-mode bypassPermissions
  code=$?
  printf '%s sortie (code %d), relance dans %ss\n' "$(date -Is)" "$code" "$RESTART_DELAY" >>"$log"
  sleep "$RESTART_DELAY"
done
