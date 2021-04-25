# Waldur Docker-compose deployment

Prerequisites:

- at least 8GB RAM on Docker Host to run all containers
- Docker v1.13+

Prepare environment:
```bash
# clone repo
git clone https://github.com/waldur/waldur-docker-compose.git
cd waldur-docker-compose
# setup settings
cp .env.example .env
```

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

Waldur HomePort will be accessible on [http://localhost](http://localhost).
API will listen on [http://localhost/api](http://localhost/api).

Tearing down and cleaning up:
```bash
docker-compose down
```

Upgrading Waldur:
```bash
docker-compose pull
docker-compose restart
```
