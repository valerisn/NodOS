# Apps

The Apps page installs popular self-hosted software with Docker. You pick an
app, NodOS pulls the image, creates a private network and named volumes for it,
starts the containers and shows you where to open it.

Docker must be on and reachable (see `docker_socket`). Only administrators can
install or remove apps; viewers can see what is installed and open it.

## What an install does

1. Checks your input: folders must be plain absolute paths, never a system
   folder; ports must be 1024 or higher.
2. Pulls every image first. If a download fails, nothing has been created.
3. Creates a network named `nodos-<app>` (apps on the host network skip this).
4. Creates and starts each container, named `nodos-<app>-<part>`, with restart
   policy `unless-stopped`, labelled `nodos.app` so NodOS can find it again.
5. Generates any database or admin passwords itself (random, 128 bits). If you
   need one to log in, it is shown once when the install finishes.

If anything goes wrong while creating containers, what was created is removed
again.

**Remove** deletes the containers and the private network but keeps the data
volumes, so installing again finds your data. Delete a volume yourself with
`docker volume rm nodos-<app>-<name>` when you are sure.

## Folders

Some apps need a folder from this server, such as your movies for Jellyfin.
You type its path in the install dialog. NodOS refuses anything with `..`,
colons, commas or spaces tricks, and refuses system locations (`/etc`, `/proc`,
`/sys`, `/dev`, `/boot`, `/root`, `/run`, `/usr`, `/bin`, `/sbin`, `/lib`,
Docker's and NodOS's own data). Media folders are mounted read-only where the
app does not need to write.

## Catalog

| App | What it is | Default port |
| --- | --- | --- |
| Jellyfin | Media server for movies, shows and music | 8096 |
| Immich | Photo and video backup (4 containers, about 4 GB RAM) | 2283 |
| Nextcloud | Files, calendar and contacts | 8082 |
| Vaultwarden | Bitwarden-compatible password manager (needs HTTPS) | 8083 |
| Home Assistant | Smart home hub (host network) | 8123 |
| Pi-hole | Network-wide ad blocking (needs port 53) | 8084 |
| AdGuard Home | DNS ad blocking with a setup wizard (needs port 53) | 3000 |
| Uptime Kuma | Service uptime monitoring | 3001 |
| Paperless-ngx | Document scanning and search (3 containers) | 8000 |
| Navidrome | Music streaming server | 4533 |
| Audiobookshelf | Audiobooks and podcasts | 13378 |
| Sonarr, Radarr, Prowlarr | TV and movie library managers and their indexer hub | 8989, 7878, 9696 |
| qBittorrent | Torrent client | 8086 |
| Nginx Proxy Manager | Reverse proxy with free certificates (ports 80, 443) | 81 |
| Syncthing | Peer to peer folder sync | 8384 |
| Gitea | Git server | 3002 |
| Mealie | Recipes and meal planning | 9925 |
| Actual Budget | Budgeting | 5006 |
| Stirling PDF | PDF tools | 8087 |
| FreshRSS | Feed reader | 8088 |
| Memos | Notes | 5230 |
| Ollama | Local language models | 11434 |
| Open WebUI | Chat interface for Ollama | 8089 |

The list follows what community surveys and roundups keep naming as the most
installed home server apps. Ports can be changed in the install dialog.

## Things to know

- **Images are pulled from public registries** and most use a moving tag such
  as `latest` or `stable`. That is convenient and means you trust each
  project's releases. Immich pins its database image because its versions have
  to match; check its release notes before updating.
- **Installing is root-equivalent**, like all Docker control. That is why it is
  admin only, needs the CSRF token and is written to the audit log
  (`app.install`, `app.remove`).
- Two apps cannot use the same host port. If one is taken, Docker's message
  appears in the install result; pick another port and try again.
- NodOS does not update installed apps. Remove and install again to get a newer
  image, or use `docker pull` yourself.
- Apps are plain containers; they also appear on the Docker page, with logs,
  start, stop and live stats.
