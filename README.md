Table of Contents
=================

   * [Docker-compose usage instructions](#docker-compose-usage-instructions)

# Docker-compose usage instructions

Prerequisites:
* at least 8GB RAM on Docker Host to run all containers
* local hostname resolution in laptop /etc/hosts: waldur-mastermind-api -> your_docker_host

Prepare environment:
```bash
# clone repo
mkdir -p ~/repos
cd ~/repos
git clone git@code.opennodecloud.com:waldur/docker-compose.git
cd ~/repos/docker-compose

# create rc file
echo $( head -c32 /dev/urandom | base64 ) > ~/waldur_secret.key
chmod 600 ~/waldur_secret.key
echo "export GLOBAL_SECRET_KEY=\"$( cat ~/waldur_secret.key )\"" > ~/waldurrc
echo "export POSTGRESQL_PASSWORD=\"waldur\"" >> ~/waldurrc

# load ENV variables
source ~/waldurrc

# create app network
docker network create waldur --driver bridge

echo never > /sys/kernel/mm/transparent_hugepage/enabled
sysctl -w vm.max_map_count=262144
sysctl -w fs.file-max=65536
```

Booting up:
```bash
# start containers
docker-compose -f docker-compose-init.yml -f docker-compose.yml up -d

# verify
docker-compose ps
docker-compose run --rm waldur-mastermind-worker status

# Create user
docker-compose run --rm waldur-mastermind-worker waldur createstaffuser -u admin -p password

```

Tearing down and cleaning up (deleting ALL volumes):
```bash
docker-compose down -v
for VOLUME in $( docker volume ls | awk '/waldur_/ { print $2 }' ); do docker volume rm $VOLUME; done
docker network rm waldur
```
