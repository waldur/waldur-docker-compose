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
docker compose up -d

# verify
docker compose ps
docker exec -t waldur-mastermind-worker status

# Create user
docker exec -t waldur-mastermind-worker waldur createstaffuser -u admin -p password -e admin@example.com

# Create demo categories for OpenStack: Virtual Private Cloud, VMs and Storage
docker exec -t waldur-mastermind-worker waldur load_categories vpc vm storage
```

Waldur HomePort will be accessible on [https://localhost](https://localhost).
API will listen on [https://localhost/api](https://localhost/api).

Healthcheck can be accessed on [https://localhost/health-check](https://localhost/health-check).

Tearing down and cleaning up:

```bash
docker compose down
```

## Logs

Logs emitted by the containers are collected and saved in the `waldur_logs` folder. You can change the location by
editing environment variable (`.env`) and updating `LOG_FOLDER` value.

## Known issues

When Waldur is launched for the first time, it applies initial database migrations.
It means that you may need to wait few minutes until these migrations are applied.
Otherwise you may observe HTTP error 500 rendered by REST API server.
This issue would be resolved after upgrade to [Docker Compose 1.29](https://docs.docker.com/compose/release-notes/#1290).

To use a custom script offering type, it should be possible to connect to `/var/run/docker.sock` from
within the Waldur containers. If you are getting a permission denied error in logs, try setting more
open permissions, for example, `chmod 666 /var/run/docker.sock`. Note that this is not a secure
setup, so make sure you understand what you are doing.

## Upgrading Waldur

```bash
docker compose pull
docker compose restart
```

## Using TLS

This setup supports following types of SSL certificates:

- Email - set environment variable TLS to your email to register Let's Encrypt account and get free automatic SSL certificates.

Example:

```bash
TLS=my@email.com
```

- Internal - set environment variable TLS to "internal" to generate self-signed certificates for dev environments

Example:

```bash
TLS=internal
```

- Custom - set environment variable TLS to "cert.pem key.pem" where cert.pem and key.pem - are paths to your custom certificates (this needs modifying docker-compose with path to your certificates passed as volumes)

Example:

```bash
TLS=cert.pem key.pem
```

## Custom Caddy configuration files

To add additional caddy config snippets into the caddy virtual host configuration add .conf files to config/caddy-includes/

## Keycloak

Keycloak is an Identity and Access Management software bundled with waldur-docker-compose.

To create a keycloak admin account set `KEYCLOAK_ADMIN` env variable in `docker-compose.yaml` and `KEYCLOAK_ADMIN_PASSWORD` in `.env` file.

After this, you can login to the admin interface at [https://localhost/auth/admin](https://localhost/auth/admin) and create Waldur users.

## Integration with SLURM

The integration is described [here](https://docs.waldur.com/admin-guide/providers/remote-slurm/).

### Whitelabeling settings

To set up whitelabeling, you need to define settings in `./config/waldur-mastermind/whitelabeling.yaml`.
You can see the list of all whitelabeling options below.

#### General whitelabeling settings

- site_name
- site_address
- site_email
- site_phone
- short_page_title
- full_page_title
- brand_color
- brand_label_color
- hero_link_label
- hero_link_url
- site_description
- currency_name
- docs_url
- support_portal_url

#### Logos and images of whitelabeling

The path to a logo is constructed like so:
/etc/waldur/icons - is a path in the container (Keep it like it is) + the name of the logo file from config/whitelabeling directory.

All-together /etc/waldur/icons/file_name_from_whitelabeling_directory

- powered_by_logo
- hero_image
- sidebar_logo
- sidebar_logo_mobile
- site_logo
- login_logo
- favicon
