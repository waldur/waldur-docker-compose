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

Healthcheck can be accessed on [https://localhost/health-check/](https://localhost/health-check/).
It answers 500 when mastermind's database, cache, storage or migrations fail,
and 200 otherwise. A Celery worker failure is reported in the body but does not
change the status. Keep the trailing slash: without it the request goes to
HomePort, which answers 200 regardless.

Tearing down and cleaning up:

```bash
docker compose down
```

## Logs

Logs emitted by the containers are collected and saved in the `waldur_logs` folder. You can change the location by
editing environment variable (`.env`) and updating `LOG_FOLDER` value.

The log files are owned by `root`. New log files are created with mode `0600` and new subfolders with
mode `0750`, so reading them on the host requires `root`. Files and folders created before the upgrade
to `docker-logger` v1.4.1 keep their old modes (`0644` and `0755`).

The `logger` container resets the ownership of everything under `LOG_FOLDER` to `root` every time it
starts. That includes automatic restarts under `restart: always`, so ownership changed on the host,
for example for a log shipper, does not last. Give such a reader access through `root` group
membership or ACLs instead.

Each time `logger` starts, it re-reads the last 10 lines of every container it follows, so a restart
repeats up to 10 lines per log file.

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

Your `.env` keeps the image tags it was copied with. First set
`WALDUR_MASTERMIND_IMAGE_TAG` and `WALDUR_HOMEPORT_IMAGE_TAG` to the versions
`.env.example` pins: the files of a release expect the images of that release.

```bash
docker compose pull
docker compose down
docker compose up -d
```

With the Matrix chat add-on, set `COMPOSE_PROFILES` in `.env` as described in
`docs/matrix-chat-add-on.md`, or pass the same `--profile` flags to each of
these commands. Without the profiles, `pull` and `up -d` neither update nor
restart the Matrix services.

### Config folder changes

Every file under `${CONFIG_FOLDER}/waldur-mastermind` listed in
`docker-compose.yml` is a **file** bind mount. If the source is missing on the
host, Docker silently creates a *directory* in its place and the startup command
that reads it fails with `IsADirectoryError`. `initdb` runs under `set -e`, so
the stack does not come up.

With the default `CONFIG_FOLDER=./config/` this cannot happen — the files arrive
with the repository. If `CONFIG_FOLDER` points at a directory of your own, diff
it against `config/waldur-mastermind/` after pulling a release and copy over
anything new.

Recently added or renamed:

- `notifications-templates.yaml` — renamed from `notification-templates.yaml`.
  The old name never took effect: `initdb` reads the plural form.
- `notifications.json` — added. Must exist even if empty (`{}`).
- `languages.yaml` — added. Must exist; ships fully commented out, which is a
  valid empty file. It seeds the language list on first start only, so language
  toggles changed in the UI are no longer reverted on restart.

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

## Outgoing email

Two independent things must be configured before Waldur sends anything. Each is
necessary and neither is sufficient:

1. **An SMTP relay.** The stack ships none, and the mastermind image's own
   placeholder is overwritten by the mounted `override.conf.py`.
2. **Enabled notifications.** Every notification type ships disabled.

A correct relay with no notifications enabled sends nothing at all, and logs
nothing to explain it.

### SMTP relay

Set the relay in `.env`; `config/waldur-mastermind/override.conf.py` reads these
and leaves Django's defaults untouched when `EMAIL_HOST` is empty:

```sh
GLOBAL_DEFAULT_FROM_EMAIL=waldur@example.com
GLOBAL_DEFAULT_REPLY_TO_EMAIL=support@example.com
EMAIL_HOST=smtp.example.com
EMAIL_PORT=587
EMAIL_USER=waldur@example.com
EMAIL_PASSWORD=s3cret
EMAIL_USE_TLS=true
```

Use `EMAIL_USE_TLS` with port 587 (STARTTLS) or `EMAIL_USE_SSL` with port 465
(implicit TLS) — never both, or Django raises at send time. Leave `EMAIL_USER`
and `EMAIL_PASSWORD` empty for a relay that accepts unauthenticated mail.

### Enabling notifications

List the notification types to enable in
`config/waldur-mastermind/notifications.json`, which is mounted into the
containers and loaded on startup:

```json
{
    "users.invitation_created": true,
    "users.invitation_approved": true,
    "marketplace.notification_usages": true
}
```

Keys not listed keep their current value. The same toggles are available at
runtime under **Administration → Notifications** in the UI.

To customise the message bodies, put the replacement templates in
`config/waldur-mastermind/notifications-templates.yaml`.

### Verifying

```sh
docker exec -it waldur-mastermind-api waldur sendtestemail you@example.org
```

This bypasses the notification system, so it isolates the relay. It does not
show up under **Support → Email logs**: that log is written by Waldur's own send
path, and only after the relay has accepted a message. An empty log with SMTP
errors in the worker logs points at the relay; an empty log with silent workers
means nothing was generated, so check the notifications above.

Full reference: [Email configuration][email-docs] in the admin guide.

[email-docs]: https://docs.waldur.com/latest/admin-guide/mastermind-configuration/email/

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

Caddy sends `Strict-Transport-Security: max-age=31536000` with HomePort's pages,
so after one visit over a trusted certificate, browsers refuse plain HTTP to
`WALDUR_DOMAIN` for a year. They ignore the header when the certificate is not
trusted, as with `TLS=internal` without its CA installed.

## Content-Security-Policy

The homeport image sends the portal's Content-Security-Policy (CSP) on every
response it serves, and builds it at start from the `CSP_*` variables in `.env`.
Caddy adds no policy to the portal's pages. It sends mastermind's API policy,
`Content-Security-Policy: default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
only on responses that carry none of their own: the error pages it generates
itself, such as a 502 while a container is down, its other answers, such as
CORS preflights, and upstream responses without a policy, such as the error
page gunicorn writes for a request it cannot parse. A policy an upstream sends
is passed on unchanged. Caddy closes the connection of an HTTPS request for
any host but `WALDUR_DOMAIN`. Such a request, by IP address or with another
`Host`, used to get an empty 200, so an external HTTPS health check that calls
the stack by IP now fails: point it at `https://${WALDUR_DOMAIN}/health-check/`
(with the trailing slash), for example with curl's
`--resolve ${WALDUR_DOMAIN}:443:<ip>`.

To check a deployment, look at a page that never reaches mastermind or
homeport:

```bash
curl -sk -X OPTIONS -H 'Origin: https://example.org' -H 'Access-Control-Request-Method: POST' \
  -D - -o /dev/null https://${WALDUR_DOMAIN}/api/ | grep -i content-security-policy
```

Caddy answers a malformed request line or an oversized header itself, before
any of this configuration applies, with a plain-text 400 or 431 that carries
no policy. Browsers do not render it as a page.

This needs a homeport image that renders the policy from its environment.
Older images send only `frame-ancestors 'none'; object-src 'none';
base-uri 'self'`, so upgrade the stack and the image together.

The API, the Matrix homeserver and LiveKit are served from `WALDUR_DOMAIN`, so
the policy's `'self'` covers them. Set the variables for anything the portal
loads from elsewhere; `.env.example` describes each one. Separate sources with
spaces: a comma, `;`, a double quote, `\` or `$` in a `CSP_*` value makes the
homeport container exit at start (only `CSP_POLICY` may hold `;`).

| Variable | Adds |
| --- | --- |
| `CSP_SENTRY_URL` | the origin the portal's Sentry SDK reports to |
| `CSP_MATOMO_URL` | the Matomo base URL |
| `CSP_MATRIX_URL`, `CSP_MATRIX_CALL_URL` | a Matrix homeserver and call signalling origin on another host |
| `CSP_INFERENCE_URL` | the inference playground origin |
| `CSP_FORM_ACTION` | SAML identity providers that use the HTTP-POST binding (`https:` for many) |
| `CSP_<DIRECTIVE>_EXTRA` | sources for one directive, e.g. `CSP_CONNECT_SRC_EXTRA` |
| `CSP_POLICY` | replaces the whole policy |

Recreate the homeport container after changing them:

```bash
docker compose up -d waldur-homeport
curl -skI https://${WALDUR_DOMAIN}/ | grep -i content-security-policy
```

### Rolling out in report-only mode

A policy that blocks something the portal needs breaks that part of the
portal, so try a new one without enforcing it:

1. Set `CSP_REPORT_ONLY=true` and `CSP_REPORT_URI` to an endpoint that
   collects reports, such as a Sentry project's security endpoint. The browser
   then reports violations but blocks nothing, except what the image keeps
   enforced alongside:
   `Content-Security-Policy: object-src 'none'; base-uri 'none'; frame-ancestors 'none'`.
2. Prove that reports arrive before trusting their absence. Open the portal,
   and in the browser console run `fetch("https://csp-check.invalid/")`. The
   fetch fails, but the policy reports a `connect-src` violation for
   `csp-check.invalid`. Check that it reaches the endpoint; in Sentry it shows
   up among the project's security reports. If it does not arrive, reports are
   not being delivered and an empty report stream proves nothing: fix the
   delivery, or watch the browser console instead.
3. Use the portal as people do: every sign-in method you offer, maps, Matrix
   chat and calls, analytics consent. Watch the reports and the browser console.
4. Add each missing source with the variables above.
5. When nothing but your own test violation is reported, remove
   `CSP_REPORT_ONLY` to enforce. Keep `CSP_REPORT_URI` to hear about
   violations later.

Reports go through `report-uri` by default. `CSP_REPORT_TO=true` also sends a
`report-to` directive and a `Reporting-Endpoints` header. Chromium then reports
only through the Reporting API and ignores `report-uri`, and those reports need
a CORS preflight that a collector, Sentry's security endpoint among them, may
not accept. Set `CSP_REPORT_TO` only after confirming that Reporting API
reports arrive, for example against Sentry on staging, with the check in
step 2. It needs `CSP_REPORT_URI`; without one the image ignores it.

### Adding a source or replacing the policy

`CSP_<DIRECTIVE>_EXTRA` appends sources to one directive. `DIRECTIVE` is the
directive name upper-cased with `-` turned into `_`: `DEFAULT_SRC`,
`SCRIPT_SRC`, `STYLE_SRC`, `IMG_SRC`, `CONNECT_SRC`, `FONT_SRC`, `MEDIA_SRC`,
`WORKER_SRC`, `FRAME_SRC` or `FORM_ACTION`. `frame-src` is the exception to
appending: it is `'none'` by default, and `CSP_FRAME_SRC_EXTRA` replaces
`'none'` rather than joining it.

```bash
CSP_CONNECT_SRC_EXTRA=https://metrics.example.com
CSP_IMG_SRC_EXTRA=https://cdn.example.com https://tiles.example.com
```

`CSP_POLICY` replaces the whole policy verbatim; `CSP_REPORT_ONLY`,
`CSP_REPORT_URI` and `CSP_REPORT_TO` still apply. Quote it, since it contains
semicolons. It must state `object-src`, `base-uri` and `frame-ancestors`, and
end every directive with `;`, or the image refuses it and homeport does not
start. A replaced policy no longer follows the portal as the image changes, so
check it after each upgrade.

```bash
CSP_POLICY="default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
```

Do not add a second policy in `config/caddy-includes/`: browsers enforce every
policy a response carries, so it can only tighten the portal's.

## Custom Caddy configuration files

To add additional caddy config snippets into the caddy virtual host configuration add .conf files to config/caddy-includes/

A response from such a route that carries no Content-Security-Policy gets
mastermind's API policy, under which a page loads nothing. If the route serves
pages, have its upstream send their policy, or set one on the route with
`header Content-Security-Policy "..."`; Caddy keeps either.

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

Two optional Compose profiles bring up a self-contained Matrix homeserver alongside Waldur — `matrix` for chat and `matrix-rtc` for voice/video calls. Activation, the automatic appservice registration, token rotation, troubleshooting, and the rest of the operator guide live in `docs/matrix-chat-add-on.md` in this repo, and on the Waldur docs site under the docker-compose deployment guide.

## Web shell (development only)

Staff can open `waldur shell` in a browser tab from the Waldur user menu. It is meant for development and demo stacks: the web shell refuses to start unless `GLOBAL_DEBUG=true`, which also switches Django's debug mode on for the whole stack.

Set in `.env`, matching your `WALDUR_DOMAIN`:

```bash
GLOBAL_DEBUG=true
WALDUR_WEB_SHELL_ENABLED=true
WALDUR_WEB_SHELL_URL=https://localhost/webshell/
```

Then start the stack with the `web-shell` profile:

```bash
docker compose --profile web-shell up -d
```

Caddy routes `/webshell/` to the `waldur-mastermind-web-shell` service (`config/caddy-includes/web-shell.conf`). That service mounts only the settings files: it deliberately has no access to the Docker socket, so a shell session cannot control the host.

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
