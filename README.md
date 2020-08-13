Table of Contents
=================

   * [Docker-compose usage instructions](#docker-compose-usage-instructions)

# Docker-compose usage instructions

Prerequisites:
* at least 8GB RAM on Docker Host to run all containers

Prepare environment:
```bash
# clone repo
git clone https://github.com/opennode/waldur-docker-compose.git
cd waldur-docker-compose

# create waldur secret key
echo $( head -c32 /dev/urandom | base64 )
```

Put generated key to `config/waldur-mastermind/override.conf.py`, `SECRET_KEY` variable or inject into `GLOBAL_SECRET_KEY` env var for `waldur-mastermind-db-migration`, `waldur-mastermind-worker`, `waldur-mastermind-beat` and `waldur-mastermind-uwsgi`.

**NB**: variable in the `override.conf.py` has higher precedence over env vars.

Booting up:
```bash
# start containers
docker-compose up -d

# verify
docker-compose ps
docker exec -t waldur-mastermind-worker status

# Create user
docker exec -t waldur-mastermind-worker waldur createstaffuser -u admin -p password -e admin@example.com
```

Waldur HomePort will be accessible on http://localhost. API will listen on http://localhost:8000

Tearing down and cleaning up:
```bash
docker-compose down
```

Upgrade:
```bash
docker-compose pull
docker-compose restart
```
