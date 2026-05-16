# Waldur Docker Compose — Development Guide

Reference Docker Compose stack that runs the full Waldur platform locally (or on a single VM) with Caddy as the TLS-terminating reverse proxy. This is the lightweight alternative to the Helm chart for demos, single-tenant deployments, and CI smoke tests.

## Repository layout

```text
waldur-docker-compose/
├── docker-compose.yml             # 14-service stack
├── .env.example                   # Tunable knobs (image tags, ports, domain, secrets, registry prefix)
├── Caddyfile                      # Reverse proxy / TLS termination config (used by caddy-router service)
├── config/                        # Bind-mounted into containers
│   ├── waldur-mastermind/         # mastermind config: auth.yaml, marketplace*.yaml, logging.conf.py, ssh keys
│   ├── waldur-homeport/           # homeport config (config.template.json), opt/ runtime tree
│   ├── waldur-slurm-service/      # SLURM site-agent config (when waldur-slurm-service.yml is composed)
│   ├── keycloak/realm.json        # Keycloak realm import (when keycloak profile is used)
│   ├── rabbitmq.conf              # RabbitMQ config
│   ├── rabbitmq-enabled-plugins
│   ├── createdb-celery_results.sql# Bootstraps the celery results DB
│   └── whitelabeling/             # Branding overrides
├── libraries/
│   └── waldur-keycloak-mapper-*.jar  # Custom Keycloak SPI mapper, loaded by keycloak service
├── waldur-slurm-service.yml       # Optional compose overlay adding waldur-site-agent for SLURM
├── db-upgrade-script.sh           # Automated Postgres major-version upgrade
└── README.md                      # User-facing operator instructions
```

## Service map

The 14 services in `docker-compose.yml`:

| Service | Image (`${DOCKER_REGISTRY_PREFIX}` prefix) | Purpose |
|---|---|---|
| `waldur-db` | `library/postgres:${WALDUR_POSTGRES_IMAGE_TAG}` | Mastermind primary DB |
| `waldur-queue` | `library/rabbitmq:4.1.2` | Celery broker |
| `waldur-launchzone-init-volume` | mastermind | One-shot init: ensures shared volume layout |
| `waldur-mastermind-db-migration` | mastermind | Runs migrations once, exits 0 |
| `waldur-mastermind-whitelabeling-init` | mastermind | Loads whitelabeling config |
| `waldur-mastermind-worker` | mastermind | Celery worker |
| `waldur-mastermind-beat` | mastermind | Celery beat scheduler |
| `waldur-mastermind-api` | mastermind | Django REST API |
| `waldur-homeport` | `opennode/waldur-homeport:${WALDUR_HOMEPORT_IMAGE_TAG}` | React SPA |
| `caddy-router` | `library/caddy:2` | TLS / reverse proxy, listens on `${WALDUR_HTTP_PORT}` / `${WALDUR_HTTPS_PORT}` |
| `keycloak` | `quay.io/keycloak/keycloak` (profile: `keycloak`) | Optional IdP |
| `keycloak-db` | postgres (profile: `keycloak`) | Keycloak's separate DB |
| `logger` | logging sidecar | Collects container logs into `${LOG_FOLDER}` |
| `default` | profile placeholder | Activates the non-optional services |

All mastermind services share `*default-mastermind-env` anchor for env variables — change the anchor once, every mastermind service inherits.

## Local workflow

```bash
cp .env.example .env

# Adjust image tags in .env (or leave defaults: 8.0.9-rc.9)
docker compose pull
docker compose up waldur-mastermind-db-migration       # one-shot migration
docker compose up -d                                   # bring stack up
docker compose ps                                      # health overview

# Create a staff user
docker exec -t waldur-mastermind-worker \
  waldur createstaffuser -u admin -p password -e admin@example.com

# Load demo OpenStack categories
docker exec -t waldur-mastermind-worker \
  waldur load_categories vpc vm storage

# UI at https://localhost (self-signed cert by default)
# API at https://localhost/api/
# Health-check at https://localhost/health-check

docker compose down                                    # stop
```

Tear-down with volumes (full reset):

```bash
docker compose down -v
```

## Profiles

- **Default** (no `--profile`): runs the core 12 services.
- **`--profile keycloak`**: also starts `keycloak` and `keycloak-db` with the realm in `config/keycloak/realm.json` and the custom mapper jar from `libraries/`.
- **`--profile slurm`** (via `waldur-slurm-service.yml` overlay):

  ```bash
  docker compose -f docker-compose.yml -f waldur-slurm-service.yml up -d
  ```

## `.env` knobs that matter

| Variable | Default | Notes |
|---|---|---|
| `WALDUR_MASTERMIND_IMAGE_TAG` / `WALDUR_HOMEPORT_IMAGE_TAG` | `8.0.9-rc.9` | Pin to a released tag, or `latest` / `develop` for tracking |
| `WALDUR_DOMAIN` | `localhost` | Used by Caddy for cert + SAN; self-signed in dev |
| `TLS` | `internal` | `email@example.org` for Let's Encrypt; `path.crt path.key` for custom |
| `WALDUR_HTTP_PORT` / `WALDUR_HTTPS_PORT` | `80` / `443` | Change to avoid host port clashes |
| `CONFIG_FOLDER` / `LOG_FOLDER` | `./config/` / `./waldur_logs` | Bind mount sources |
| `GLOBAL_SECRET_KEY` | `changeme` | Django SECRET_KEY — **always override in production** |
| `POSTGRESQL_PASSWORD` / `KEYCLOAK_POSTGRESQL_PASSWORD` / `KEYCLOAK_ADMIN_PASSWORD` | `default` / `changeme` / `changeme` | **Always override in production** |
| `WALDUR_POSTGRES_IMAGE_TAG` / `KEYCLOAK_POSTGRES_IMAGE_TAG` | `16` | Major version pins — coordinate upgrades with `db-upgrade-script.sh` |
| `RABBITMQ_USERNAME` / `RABBITMQ_PASSWORD` | `waldur` / `waldur` | Broker credentials |
| `DOCKER_GROUP_ID` | `0` (Docker Desktop) | On Linux, set to `getent group docker` so containers can use `/var/run/docker.sock` for the script offering type |
| `DOCKER_REGISTRY_PREFIX` | `docker.io/` | CI uses `registry.hpc.ut.ee/mirror/` to avoid rate limits |
| `SENTRY_DSN` / `SENTRY_ENVIRONMENT` | unset / `docker-compose-demo` | Optional error reporting |
| `EXTRA_HOST` | `host1.example.com:127.0.0.1` | Extra `/etc/hosts` entry inside containers |
| `POSTGRESQL_READONLY_USER` / `POSTGRESQL_READONLY_PASSWORD` | commented out | Enable readonly DB user for `/api/query/` |

## Upgrading Waldur

```bash
# Bump WALDUR_MASTERMIND_IMAGE_TAG and WALDUR_HOMEPORT_IMAGE_TAG in .env, then:
docker compose pull
docker compose down
docker compose up -d
```

## Upgrading Postgres major versions

The bundled `db-upgrade-script.sh` automates `pg_dumpall` + bind-mount swap. See README "Upgrade Instructions for PostgreSQL Images" for the full procedure. Always:

1. Run while the stack is **on the old major version**.
2. Update `WALDUR_POSTGRES_IMAGE_TAG` (and/or `KEYCLOAK_POSTGRES_IMAGE_TAG`) **after** the script reports success.
3. Take a backup of `${LOG_FOLDER}/../db-data` (or wherever the postgres volume lives) before starting.

## Test stack as a debugging tool for upstream MRs

This stack is the canonical way to validate a `waldur-mastermind` or `waldur-homeport` MR against a real Postgres + RabbitMQ + Celery + Caddy environment without a Kubernetes cluster. Two patterns:

### Run against a custom locally-built image

Build the upstream repo locally, then override the image in `.env`:

```bash
cd ../waldur-mastermind
docker build -t opennode/waldur-mastermind:local-fix .

cd ../waldur-docker-compose
# In .env:
#   WALDUR_MASTERMIND_IMAGE_TAG=local-fix
#   DOCKER_REGISTRY_PREFIX=
docker compose up -d --force-recreate
```

The same pattern works for `waldur-homeport` (`opennode/waldur-homeport:local-fix`). This is essentially the same swap CI does via `WALDUR_MASTERMIND_IMAGE` overrides, but for the standard `docker-compose.yml`.

### Apple Silicon caveats

On M-series Macs, mastermind's `Dockerfile` may fail when an `openportal` dependency lacks an `aarch64` wheel. Either upgrade the pin in `waldur-mastermind/uv.lock` (`pip index versions openportal`) or rebuild with `--platform linux/amd64` (slow, QEMU).

## CI behaviour

CI pulls templates from `waldur/waldur-pipelines`. Jobs:

| Job | When | What |
|---|---|---|
| `Test compose configuration` | MRs / develop / master / scheduled / pipeline-triggered | Brings the full stack up using the HPC mirror registry, runs migrations, creates a staff user, smoke-tests `/api/` (expects 401), `/` (expects 200), `/api-auth/password/` (POSTs admin creds, expects 200) |
| `Trigger dev env update` | tag / default branch | Deploys to the dev environment via `dev-env-update.yml` from waldur-pipelines |
| `check-merge-compatibility` | MRs | Validates the MR can fast-merge into target |
| `lint-md-files` | MRs | Markdown lint via shared template |

When CI runs from a triggered pipeline:

- `TRIGGER_PROJECT_NAME=waldur-mastermind` → uses `TRIGGER_IMAGE_TAG` for `WALDUR_MASTERMIND_IMAGE_TAG`.
- `TRIGGER_PROJECT_NAME=waldur-homeport` → same for `WALDUR_HOMEPORT_IMAGE_TAG`.

For MR pipelines (no trigger), both image tags get rewritten to `latest` in `.env` before `docker compose up`.

## Conventions / gotchas

- **Bind-mount config layout**: anything mastermind reads from `/etc/waldur/` (auth, marketplace, logging, scripts) lives in `config/waldur-mastermind/`. New required files need both a file here and a volume entry in the relevant services.
- **`*default-mastermind-env` anchor**: changes to mastermind env vars only need to be made once; the YAML anchor is shared across `worker`, `beat`, `api`, `whitelabeling-init`, `db-migration`, `launchzone-init-volume`.
- **First-launch HTTP 500**: migrations take a few minutes on the very first `up`. README documents this; for CI we explicitly run `waldur-mastermind-db-migration` standalone first.
- **Script offering type permission**: containers need access to `/var/run/docker.sock`. Set `DOCKER_GROUP_ID=$(getent group docker | cut -d: -f3)` on Linux. On macOS Docker Desktop, use `0`.
- **Caddy `tls internal`**: default self-signed cert won't be trusted by curl/browsers without `-k` / "Accept Risk". Use a real email or custom cert for any externally reachable deployment.
- **Custom keycloak mapper**: when upgrading Keycloak major versions, verify `libraries/waldur-keycloak-mapper-*.jar` is still SPI-compatible.
- **DB cache survives container restart**: mastermind uses `django.core.cache.backends.db.DatabaseCache`. After upgrading a backing service that changes the keystone catalog (etc.), clear the cache from inside the worker container:

  ```bash
  docker exec waldur-mastermind-worker \
    sh -c "DJANGO_SETTINGS_MODULE=waldur_core.server.settings python3 -c \
      'from django.core.cache import cache; cache.clear()'"
  ```

## Relationship to waldur-helm

This stack and the Helm chart cover the same product but different deployment targets. When adding a new mandatory mastermind setting:

1. Edit `config/waldur-mastermind/<file>` here.
2. Add the equivalent rendered value in `waldur-helm/waldur/templates/config-*.yaml` and `waldur-helm/waldur/values.yaml`.
3. Document it once in `waldur-docs` (the helm `docs/` tree gets synced there).

Keep the two stacks in sync — a feature available only via Docker Compose but not via Helm (or vice-versa) is a release-blocker.
