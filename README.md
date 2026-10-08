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

Depuis un vrai terminal sur piserv (SSH), pas depuis le préfixe `!` de Claude Code, qui n'a
pas de TTY. Le tmux ne contient que le serveur `claude remote-control`, qui sort tant que le
conteneur n'est pas connecté : la connexion se fait donc à part.

```bash
docker compose exec claude claude auth login   # abonnement claude.ai, pas de clé API
docker compose exec claude tmux attach -t claude
```

Le login ouvre une URL à valider dans le navigateur, puis attend le code à coller. Dans
tmux, au plus 10 s plus tard, le serveur redémarre et demande « Trust /workspace? »,
« Enable Remote Control? » et l'avertissement du mode bypass : répondre `y`. Détacher avec
`Ctrl-b d`, jamais `Ctrl-c`. La session `piserv-dev` apparaît alors dans claude.ai/code.
`docker compose exec claude claude auth status` doit répondre `"loggedIn": true`.

## Usage

- Les projets vivent dans le volume `workspace`, sous `/workspace`. Une session part de
  `/workspace` et fait `cd` vers le projet voulu.
- Un serveur de dev, natif ou lancé par `docker compose` dans le conteneur, se publie sur
  un port de `4100-4119` et se consulte sur l'hôte à `127.0.0.1:<port>`, par tunnel SSH
  par exemple : `ssh -L 4100:127.0.0.1:4100 piserv`.
- Dans le conteneur, `hostname` répond `claude-env` : ce n'est pas la prod de piserv.
- `~/supervisor.log` journalise chaque relance de `claude remote-control`.
- La config Claude vient de [my-claude-config](https://github.com/Jjiroos/my-claude-config),
  mise à jour par `git pull` à chaque démarrage du conteneur.

## Forges

`FORGEJO_URL` reçoit l'URL publique du Forgejo (son `ROOT_URL`). Elle n'est jamais versionnée, car
ce dépôt est public. Les tokens sont dédiés et révocables sans toucher aux accès personnels :

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
