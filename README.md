# Waldur Docker-compose deployment

## Prerequisites

- at least 8GB RAM on Docker Host to run all containers
- Docker v1.13+

## Prepare environment

```bash
# clone repo
git clone https://github.com/waldur/waldur-docker-compose.git
cd waldur-docker-compose
# setup settings
cp .env.example .env
```

## Booting up

```bash
# start containers
docker-compose up -d

# verify
docker-compose ps
docker exec -t waldur-mastermind-worker status

# Create user
docker exec -t waldur-mastermind-worker waldur createstaffuser -u admin -p password -e admin@example.com

# Create demo categories for OpenStack: Virtual Private Cloud, VMs and Storage
docker exec -t waldur-mastermind-worker waldur load_categories vpc vm storage
```

Waldur HomePort will be accessible on [http://localhost](http://localhost).
API will listen on [http://localhost/api](http://localhost/api).

Healthcheck can be accessed on [http://localhost/health-check](http://localhost/health-check).

Tearing down and cleaning up:

```bash
docker-compose down
```

## Logs

Logs emitted by the containers are collected and saved in the `waldur_logs` folder. You can change the location by
editing environment variable (`.env`) and updating `LOG_FOLDER` value.

## Known issues

When Waldur is launched for the first time, it applies initial database migrations.
It means that you may need to wait few minutes until these migrations are applied.
Otherwise you may observe HTTP error 500 rendered by REST API server.
This issue would be resolved after upgrade to [Docker Compose 1.29](https://docs.docker.com/compose/release-notes/#1290).

## Upgrading Waldur

```bash
docker-compose pull
docker-compose restart
```

## Using TLS

1. Add private key and certificate to ``./certs`` folder.
2. Edit docker-compose.yml and replace port section with '80'. This is needed to force HTTP->HTTPS redirect from a TLS proxy: `sed -i 's/${WALDUR_INTERNAL_PORT}:80/80/' docker-compose.yml`.
3. Change `WALDUR_PUBLIC_PORT` in .env to 443 and `WALDUR_PROTOCOL` to https.
4. Start docker-compose with an extra TLS proxy:

```bash
# start containers
docker-compose -f docker-compose.yml -f tls-proxy.yml up -d
```
