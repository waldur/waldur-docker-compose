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
docker compose down
docker compose up -d
```

## Upgrade Instructions for PostgreSQL Images

### Automated Upgrade (Recommended)

To simplify the upgrade process, an upgrade script `db-upgrade-script.sh` is included in the root directory. This script automates the entire upgrade process.

#### Usage Instructions

1. **Ensure Waldur is running with the current (old) PostgreSQL version that you wish to upgrade from**:

   ```bash
   docker compose up -d
   ```

2. **Update the PostgreSQL versions in `.env` file**:

    ```sh
    WALDUR_POSTGRES_IMAGE_TAG=<your_version>
    KEYCLOAK_POSTGRES_IMAGE_TAG=<your_version>
    ```

3. **Ensure the script has execution permissions**:

   ```bash
   chmod +x db-upgrade-script.sh
   ```

4. **Run the upgrade script**:

   ```bash
   ./db-upgrade-script.sh
   ```

> **Important**: The script needs the containers to be running with the old PostgreSQL version first so it can back up the existing data before upgrading.

The script will automatically:

- Back up both databases
- Shut down all containers
- Remove old data directories and volumes
- Pull new PostgreSQL images
- Start containers with new PostgreSQL versions
- Restore data from backups
- Create SCRAM tokens for PostgreSQL 14+ compatibility
- Start all containers

### Manual Upgrade (Alternative)

If you prefer to perform the upgrade manually, follow these steps:

#### Manual Prerequisites

- Backup existing data (if needed)

#### Backup Commands

You can back up the database using `pg_dumpall`.

**For Waldur DB:**

```bash
docker exec -it waldur-db pg_dumpall -U waldur > /path/to/backup/waldur_upgrade_backup.sql
```

**For Keycloak DB:**

```bash
docker exec -it keycloak-db pg_dumpall -U keycloak > /path/to/backup/keycloak_upgrade_backup.sql
```

#### Manual Upgrade Steps

1. **Update PostgreSQL Versions**

    Update the `WALDUR_POSTGRES_IMAGE_TAG` and `KEYCLOAK_POSTGRES_IMAGE_TAG` in the `.env` file to the required versions.

    ```sh
    WALDUR_POSTGRES_IMAGE_TAG=<your_version>
    KEYCLOAK_POSTGRES_IMAGE_TAG=<your_version>
    ```

2. **Shut down containers**

    ```bash
    docker compose down
    ```

3. **Remove old data directories**

    > **Note:**
    > The waldur-db uses a bind mount (`./pgsql`) while keycloak-db uses a named volume (`keycloak_db`). Both need to be removed before upgrading.
    > **Warning**: This action will delete your existing PostgreSQL data. Ensure it is backed up before proceeding.

    **Remove the pgsql directory (waldur-db data):**

    ```bash
    sudo rm -r pgsql/
    ```

    **Remove the keycloak_db volume:**

    ```bash
    docker volume rm waldur-docker-compose_keycloak_db
    ```

4. **Pull the New Images**

    ```bash
    docker compose pull
    ```

5. **Start database containers**

    ```bash
    docker compose up -d waldur-db keycloak-db
    ```

6. **Restore Data** *(if backups have been made)*

    **For Waldur DB:**

    ```bash
    cat waldur_upgrade_backup.sql | docker exec -i waldur-db psql -U waldur
    ```

    **For Keycloak DB:**

    ```bash
    cat keycloak_upgrade_backup.sql | docker exec -i keycloak-db psql -U keycloak
    ```

7. **Create SCRAM tokens** *(for PostgreSQL 14+)*

    If the new PostgreSQL version is 14 or later, create SCRAM tokens for existing users:

    ```bash
    export $(cat .env | grep "^POSTGRESQL_PASSWORD=" | xargs)
    docker exec -it waldur-db psql -U waldur -c "ALTER USER waldur WITH PASSWORD '${POSTGRESQL_PASSWORD}';"
    export $(cat .env | grep "^KEYCLOAK_POSTGRESQL_PASSWORD=" | xargs)
    docker exec -it keycloak-db psql -U keycloak -c "ALTER USER keycloak WITH PASSWORD '${KEYCLOAK_POSTGRESQL_PASSWORD}';"
    ```

8. **Start all containers**

    ```bash
    docker compose up -d
    ```

9. **Verify the Upgrade**

    Verify the containers are running with the new PostgreSQL version:

    ```bash
    docker ps -a
    ```

    Check container logs for errors:

    ```bash
    docker logs waldur-db
    docker logs keycloak-db
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

Keycloak is an optional Identity and Access Management software that can be enabled with a Docker Compose profile.

To start Waldur with Keycloak:

```bash
docker compose --profile keycloak up -d
```

The default Keycloak admin username is `admin` (set via `KEYCLOAK_ADMIN` in `docker-compose.yml`). Set the admin password via `KEYCLOAK_ADMIN_PASSWORD` in the `.env` file.

After this, you can login to the admin interface at [https://localhost/auth/admin](https://localhost/auth/admin) and create Waldur users.

To use Keycloak as an identity provider within Waldur, follow the instruction [here](https://docs.waldur.com/latest/admin-guide/identities/keycloak/).
The discovery url to connect to Keycloak from the waldur-mastermind-api container is:

```bash
http://keycloak:8080/auth/realms/<YOUR REALM>/.well-known/openid-configuration
```

## Matrix chat add-on

Two optional Compose profiles bring up a self-contained Matrix homeserver alongside Waldur — `matrix` for chat and `matrix-rtc` for Element Call voice/video. Activation, the one-time appservice registration, troubleshooting, and the rest of the operator guide live in [docs/matrix-chat-add-on.md](docs/matrix-chat-add-on.md).

## Integration with SLURM

The integration is described [here](https://docs.waldur.com/latest/admin-guide/providers/site-agent/).

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

## Readonly PostgreSQL user configuration

In order to enable /api/query/ endpoint please make sure that read-only user is configured both in PostgreSQL and in the environment variables.

The endpoint executes caller-supplied SQL against the read replica, so the calling Waldur user must have the `is_staff` flag set. (Prior to Waldur 8.x the endpoint also accepted `is_support` users; this was tightened to staff-only because even a SELECT-only DB role still exposes token hashes, password hashes, and PII.)

### 1. Create PostgreSQL readonly user

```sql
-- Create a read-only user
CREATE USER readonly WITH PASSWORD '{readonly_password}';

-- Grant read-only access to the database
GRANT CONNECT ON DATABASE {database_name} TO {readonly_username};

-- Grant read-only access to the schema
GRANT USAGE ON SCHEMA public TO {readonly_username};

-- Grant read-only access to existing tables
GRANT SELECT ON ALL TABLES IN SCHEMA public TO {readonly_username};

-- Grant read-only access to future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO {readonly_username};

-- Revoke access to authtoken_token table
REVOKE SELECT ON authtoken_token FROM {readonly_username};
```

### 2. Configure environment variables

Add the following environment variables to your `.env` file:

```bash
POSTGRESQL_READONLY_USER={readonly_username}
POSTGRESQL_READONLY_PASSWORD={readonly_password}
```

**Note**: Replace `{readonly_password}` with the actual password you used when creating the readonly user, and `{readonly_username}` with your chosen readonly username (e.g., "readonly").

## Migration from bitnami/postgresql to library/postgres DB image

After migration from the bitnami/postgresql to library/postgres DB image, you might notice a working in logs like this:

```log
...
WARNING:  database "waldur" has a collation version mismatch
DETAIL:  The database was created using collation version 2.36, but the operating system provides version 2.41.
...
```

In this case, you can simply update the collaction version and reindex the Waldur DB and the public schema:

```postgresql
-- Run these commands in the psql shell of the waldur-db container

ALTER DATABASE waldur REFRESH COLLATION VERSION;
ALTER DATABASE postgres REFRESH COLLATION VERSION;
ALTER DATABASE celery_results REFRESH COLLATION VERSION;
ALTER DATABASE template1 REFRESH COLLATION VERSION;

REINDEX DATABASE waldur;
REINDEX SCHEMA public;
```
