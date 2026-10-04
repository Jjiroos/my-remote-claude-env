# my-claude-env — design

Date : 2026-10-04 · Hôte cible : `piserv` (Raspberry Pi 5, aarch64, 8 Go, Docker 29, Compose v5)

## Objectif

Un environnement de dev conteneurisé où Claude Code tourne en permanence, piloté à distance
depuis claude.ai/code et l'app mobile (Remote Control), pour produire applications et tâches de dev
avec une autonomie complète **dans** le conteneur et aucun accès à la prod de piserv
(mycollectbuddy, Forgejo, leurs bases).

### Critères de succès

- `docker compose up -d` suffit à (re)lancer l'environnement ; il survit aux redémarrages de l'hôte.
- Après un unique `/login` manuel, la session est joignable depuis claude.ai/code sans terminal.
- Claude peut builder et lancer des apps (natif ou `docker compose`) et les exposer en local sur l'hôte.
- Claude peut pousser vers Forgejo et GitHub avec des tokens dédiés et révocables.
- Aucun chemin vers le démon Docker de l'hôte, ses fichiers ou ses réseaux de prod.

### Hors périmètre

- Mode agent autonome sur file de tâches (issues) : à concevoir plus tard si besoin.
- Runtime Sysbox (suppression du `privileged` de dind) : demande une installation sur l'hôte de prod.
- Exposition LAN ou Internet des apps produites.

## Architecture

Docker Compose, deux services :

| Service | Image | Rôle |
|---|---|---|
| `dind` | `docker:dind` | Démon Docker isolé, `privileged`, données dans le volume `dind-data`. Porte l'espace réseau partagé et la publication des ports. |
| `claude` | build local (`Dockerfile`) | Claude Code en mode serveur Remote Control, toolchains, utilisateur non root `dev`. `network_mode: service:dind`. |

Le partage d'espace réseau (`network_mode: service:dind`) fait que :

- le démon est joint par `claude` sur `tcp://127.0.0.1:2375`, sans TLS, car il n'écoute que sur la boucle locale de l'espace partagé, inaccessible hors des deux conteneurs ;
- un serveur de dev natif dans `claude` et un port publié par un `docker compose` lancé dans `dind` sont tous deux joignables sur `localhost`, et la plage de ports n'est publiée qu'une fois, sur le service `dind`.

### Arborescence

```
my-claude-env/
├── compose.yaml          services claude + dind, volumes, ports, limites
├── Dockerfile            image claude
├── entrypoint.sh         préparation au démarrage, puis tmux + supervisor
├── supervisor.sh         boucle claude remote-control, relance à la sortie
├── scripts/smoke-test.sh vérification de bout en bout
├── .env.example          variables attendues (tokens, ports, limites)
├── .gitignore            .env
└── README.md             installation, premier login, rotation des tokens, usage
```

## Image `claude`

- Base `ubuntu:26.04` (LTS, avril 2026).
- L'utilisateur `ubuntu` (UID 1000) de l'image est renommé `dev`, avec un home `/home/dev` (UID aligné sur l'utilisateur `pibot` de l'hôte).
- Toolchains :
  - Node LTS (24), npm et npx (archive officielle, somme vérifiée) ;
  - Python système d'Ubuntu, piloté par `uv` (`/usr/local/bin`) ;
  - OpenJDK 25 par défaut et OpenJDK 21 à côté (paquets Ubuntu), avec Maven ;
  - Go (archive officielle, version fixée par `GO_VERSION`) ;
  - Rust via `rustup`, installé dans `/opt/rust` (`RUSTUP_HOME`, `CARGO_HOME`) et appartenant à `dev`.
- Outils : git, gh (dépôt officiel), docker CLI avec les plugins compose et buildx (dépôt Docker), tmux, jq, ripgrep, shellcheck, curl, build-essential.
- `dev` a `sudo` sans mot de passe, limité au conteneur, pour que Claude puisse installer des paquets.
- Claude Code est installé avec l'installeur natif dans `/home/dev/.local`, et se met à jour seul dans le volume `home`.

Seul Claude Code vit dans le volume `home` parmi les outils. Docker pré-remplit un volume neuf avec le contenu de l'image, et l'entrypoint réinstalle Claude Code s'il est absent. Les autres toolchains viennent de l'image et suivent ses reconstructions.

## Démarrage et supervision

`entrypoint.sh` (lancé par `dev`) :

1. Échoue si `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` ou `ANTHROPIC_BASE_URL` sont définis, car Remote Control exige l'auth claude.ai.
2. Installe Claude Code dans le home s'il est absent.
3. Configure git : identité `Claude (piserv-dev)`, et un credential helper qui sert `GH_TOKEN` à `github.com` et `FORGEJO_TOKEN` à l'hôte Forgejo. Aucun token n'apparaît dans une URL ni dans `~/.gitconfig`.
4. Clone `https://github.com/Jjiroos/my-claude-config` dans `/home/dev/my-claude-config` au premier démarrage (ensuite `git pull --ff-only`), puis lance son `install.sh`. Un échec réseau à cette étape est signalé sans bloquer le démarrage.
5. Avec des arguments, exécute la commande demandée (tests, maintenance) au lieu de la suite.
6. Démarre une session tmux `claude` exécutant `supervisor.sh`, puis reste au premier plan en attendant la fin de cette session tmux.

`supervisor.sh` boucle dans `/workspace` :

```
claude remote-control --name "${RC_NAME}" --permission-mode bypassPermissions
```

À chaque sortie, il journalise le code et la date, attend `RESTART_DELAY` secondes (10 par défaut), puis relance. Une relance dans le même dossier récupère les sessions pendant environ 4 heures (doc Remote Control). Le serveur sort de lui-même après environ 10 minutes sans réseau, d'où la boucle.

Mode `same-dir` : les sessions partent de `/workspace` et font `cd` vers le projet voulu (`/workspace` contient plusieurs dépôts, et le mode `worktree` exige un dépôt git à la racine).

Le premier démarrage demande un geste manuel, car Remote Control exige un TTY pour la confiance du dossier et la confirmation :

```
docker compose exec claude tmux attach -t claude
# /login, puis accepter « Trust /workspace? » et « Enable Remote Control? » ; Ctrl-b d
```

## Volumes

| Volume | Monté sur | Contenu |
|---|---|---|
| `home` | `claude:/home/dev` | auth Claude, `~/.claude`, my-claude-config, caches uv/cargo/npm/maven/go |
| `workspace` | `claude:/workspace` | projets |
| `dind-data` | `dind:/var/lib/docker` | images et conteneurs du démon isolé |

Aucun bind mount de l'hôte.

## Réseau et ports

- La plage `127.0.0.1:${PORT_RANGE}` (4100-4119 par défaut, libre sur piserv au 2026-10-04) est publiée sur le service `dind`, seulement sur la boucle locale de l'hôte.
- **Forgejo** est joint par son URL publique, celle de son `ROOT_URL`, fournie par `FORGEJO_URL` dans `.env`. Elle est obligatoire et jamais versionnée, car le dépôt est public. Il n'écoute que sur `127.0.0.1:3000` de l'hôte, donc `host.docker.internal` ne le joint pas, et rejoindre `forgejo_forgejo-net` exposerait `forgejo-db`.

## Identifiants et sécurité

- `.env` (ignoré par git, `chmod 600`) porte `GH_TOKEN`, `FORGEJO_TOKEN` et `FORGEJO_URL`. Seul `.env.example` est versionné.
- `GH_TOKEN` : fine-grained PAT, limité aux dépôts choisis, avec contents et pull requests en lecture/écriture.
- `FORGEJO_TOKEN` : token d'un utilisateur Forgejo dédié (`claude-bot`), collaborateur des dépôts voulus.
- L'auth Claude reste dans le volume `home` et n'est jamais dans `.env`.
- `bypassPermissions` vaut dans le conteneur. Les garde-fous sont structurels : pas de socket Docker de l'hôte, pas de bind mount, ports en local seulement.
- Risque accepté : `dind` est `privileged`. Le service `claude` ne l'est pas, et le démon n'est joint que par la boucle locale partagée.
- Le CLAUDE.md cloné continue de s'appliquer : commits locaux, push ou PR sur demande explicite.

## Ressources

Plafonds réglables dans `.env` : `claude` à 3 Go et 3 CPU, `dind` à 2 Go. Les deux services sont en `restart: unless-stopped`.

## Vérification

`scripts/smoke-test.sh`, lancé depuis l'hôte après `docker compose up -d --build`, sort en erreur au premier échec :

1. **Toolchains :** `node`, `npx`, `uv run python --version`, `java -version` (25 par défaut), présence du JDK 21, `mvn`, `go`, `cargo` et `claude --version`, sous `dev`.
2. **Docker isolé :** `docker run --rm hello-world` passe par `dind`, et `docker ps -a` ne liste aucun conteneur de l'hôte.
3. **Ports :** un `python3 -m http.server 4100` lancé dans `claude` répond depuis l'hôte sur `127.0.0.1:4100`, et pas sur l'IP LAN.
4. **Forges :** `git ls-remote` réussit vers un dépôt Forgejo et un dépôt GitHub (dépôts fixés par `SMOKE_FORGEJO_REPO` et `SMOKE_GITHUB_REPO`). Ignoré avec un avertissement si les tokens sont absents.
5. **Supervision :** un `pkill -f 'claude remote-control'` est suivi d'une relance par la boucle dans le délai prévu. Ignoré si le login n'est pas encore fait.

Non vérifiable automatiquement : la connexion depuis claude.ai/code et le mobile après `/login`.
