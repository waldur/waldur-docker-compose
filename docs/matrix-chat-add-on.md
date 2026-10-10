# Matrix chat add-on

Waldur ships an optional Matrix chat integration (the `matrix_chat` Django app and the homeport `src/matrix/` views). When the add-on is enabled, project members can chat in per-project Matrix rooms; with the `matrix-rtc` sub-profile they can also start voice/video calls from the chat.

The add-on bundles a [Tuwunel](https://github.com/matrix-construct/tuwunel) homeserver (the same image used by the upstream dev stack) wired into the Caddy reverse proxy on the same domain — no extra DNS, no federation port. Tokens are auto-generated on first start and persisted in a Docker volume.

## Activation

Chat only:

```bash
docker compose --profile matrix up -d
```

Chat + voice/video calls, with `WALDUR_MATRIX_RTC_ENABLED=true` in `.env`:

```bash
docker compose --profile matrix --profile matrix-rtc up -d
```

The `matrix-rtc` profile adds only the LiveKit media server; calls also need the `matrix` profile. See [Calls](#calls) for how clients get call tokens.

The add-on runs `waldur init_matrix_settings` and `waldur register_matrix_appservice` from the mastermind image, so it needs `WALDUR_MASTERMIND_IMAGE_TAG` at the version `.env.example` pins or newer. With an older image `waldur-matrix-init` fails on the unknown command and Tuwunel never starts.

## Pinned image tags

Matrix component versions live in `.env`. Bump them deliberately:

| Variable | Default | Component |
|---|---|---|
| `WALDUR_TUWUNEL_IMAGE_TAG` | `v1.9.3` | Tuwunel homeserver — requires 1.7.0+ for Synapse-compatible `registration_shared_secret`. **Kept in lockstep with the Helm chart's `matrixChat.homeserver.imageTag`** — one supported homeserver version across both packaging paths |
| `WALDUR_LIVEKIT_IMAGE_TAG` | `v1.13.7` | LiveKit SFU |

Both publish multi-arch (`linux/amd64` and `linux/arm64`) manifests for the pinned tags. Re-check with `docker buildx imagetools inspect <image>:<tag>` after bumps.

**Back up before bumping Tuwunel.** It migrates its embedded database in place
on the first boot of a new version, before it listens (from 1.9.1 it logs its
progress every fifteen seconds; earlier versions log nothing), so read the
[upstream release notes](https://github.com/matrix-construct/tuwunel/releases)
before moving in either direction. A `tuwunel` container that is up but not
answering `/_matrix/client/versions` is migrating, not hung: do not restart it,
a restart mid-migration corrupts the database.

**Downgrades are the dangerous direction.** An older Tuwunel boots cleanly on a
migrated database and then silently serves stale data from the old stores. Stop
the stack and back up the `tuwunel_data` volume before changing the tag;
restoring that backup is the only rollback. The Helm chart's
[Matrix chat guide](https://docs.waldur.com/latest/admin-guide/deployment/helm/docs/matrix-chat/)
has the upgrade and CVE-response procedure, which applies to both packaging
paths.

**`WALDUR_DOMAIN` is frozen once the homeserver has data.** It is the Matrix
`server_name`, baked into every user and room ID. From 1.9.0 the homeserver
also stamps it into the database on first boot and refuses to start under a
different name:

```text
Critical error starting server: Database belongs to old.example; configured server name is new.example. Cannot reuse.
```

That is not a bug to work around by wiping `tuwunel_data` — wiping it discards
the whole chat corpus. Changing the domain means a fresh homeserver.

## Appservice registration

Tuwunel does not load appservice descriptors from a file — it requires registration via the `!admin appservices register` admin-room command. This is handled for you: the one-shot `waldur-matrix-register` container runs after the homeserver comes up, drives that admin-room command and makes the bot a homeserver admin (see below). There is nothing to paste.

On a new homeserver it first creates a bootstrap admin, `@waldur-bootstrap`, through Tuwunel's shared-secret registration API on the internal network. The generated registration token is the shared secret, and `BOOTSTRAP_PASSWORD` from the secrets volume becomes the account's password. That first run uses the token the registration returns, so it works with password login off. Later runs sign in as `@waldur-bootstrap` with that password, and every run signs the bootstrap session out when it is done.

```bash
docker compose --profile matrix up -d
docker wait waldur-matrix-register   # prints its exit code once it is done; 0 means registered
docker logs waldur-matrix-register
# Expect: Appservice 'waldur' registered on the homeserver.
```

`up -d` returns before registration is done: nothing depends on the register
container, and it may still be waiting for the homeserver. Read its log once
`docker wait` has returned.

The register container waits for the homeserver before it does anything, up to
`WALDUR_MATRIX_REGISTER_WAIT_SECONDS` (default one hour), logging every 30 s.
After a Tuwunel bump that wait covers the in-place database migration, which
runs silently before the homeserver listens and scales with the volume size.
If the log shows the container gave up, raise the limit and `up` again — do not
restart `tuwunel`.

Re-running `up -d` is safe. With a working appservice token, the command signs in, compares the homeserver's registration with Waldur's and replaces it when the URL, a token or a namespace differs; otherwise it changes nothing. [Registering on Tuwunel from the command line](https://docs.waldur.com/latest/developer-guide/admin-guide/matrix-appservice-setup/#registering-on-tuwunel-from-the-command-line) has the details.

The register container refuses to run, and exits 1, when `secrets.env` has no
`BOOTSTRAP_PASSWORD`, as a file from before automatic registration does. Its
log says how to add one.

### Registering by hand

Set `WALDUR_MATRIX_REGISTER_APPSERVICE=false` to keep registration entirely
manual. `waldur-matrix-init` still renders the descriptor into the
`waldur_matrix_secrets` volume with mastermind's
`generate_appservice_registration`, so it claims the same user and room-alias
namespaces the register container would.

The default config has `WALDUR_MATRIX_OPEN_REGISTRATION=false`, so client-side registration (Element Web sign-up form) is disabled. Use Tuwunel's Synapse-compatible admin endpoint (HMAC-keyed by the registration secret) to provision the admin user. That endpoint is not served through Caddy, so the snippet below runs inside the Compose network, in a throwaway `waldur-matrix-init` container that has the secrets volume mounted. It does the whole thing — create the admin, find the admin room, post the `!admin appservices register` message with the descriptor and then `!admin users make-user-admin` for the bot, print Tuwunel's replies. Choose the admin's username, and type its password at the prompt, so it lands neither in shell history nor on a command line:

```bash
read -rs -p 'Matrix admin password: ' ADMIN_PASSWORD && echo && export ADMIN_PASSWORD
ADMIN_USER=matrix-admin docker compose run --rm --no-deps -T \
  -e ADMIN_USER -e ADMIN_PASSWORD --entrypoint python3 waldur-matrix-init - <<'EOF'
import hashlib, hmac, json, os, time, urllib.parse, urllib.request

USERNAME, PASSWORD = os.environ["ADMIN_USER"], os.environ["ADMIN_PASSWORD"]
HOMESERVER = "http://tuwunel.internal:6167"
SHARED = "/var/lib/waldur/matrix"  # the waldur_matrix_secrets volume

if not PASSWORD:
    raise SystemExit("Set ADMIN_PASSWORD before running this script")


def call(method, path, body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(HOMESERVER + path, data, headers, method=method)
    with urllib.request.urlopen(request) as response:
        return json.load(response)


secrets = dict(line.split("=", 1) for line in open(f"{SHARED}/secrets.env").read().split())

# Register the admin via Synapse-compatible HMAC
nonce = call("GET", "/_synapse/admin/v1/register")["nonce"]
message = "\0".join([nonce, USERNAME, PASSWORD, "admin"]).encode()
mac = hmac.new(secrets["REG_TOKEN"].encode(), message, hashlib.sha1).hexdigest()
admin = call("POST", "/_synapse/admin/v1/register", {
    "nonce": nonce, "username": USERNAME, "password": PASSWORD, "admin": True, "mac": mac,
})
token, user_id = admin["access_token"], admin["user_id"]
server_name = user_id.split(":", 1)[1]

# The admin joins the admin room, #admins:<server name>
alias = urllib.parse.quote("#admins:" + server_name)
room = urllib.parse.quote(call("GET", f"/_matrix/client/v3/directory/room/{alias}")["room_id"])


def command(body):
    """Post an admin-room command and print Tuwunel's reply to it."""
    sent = call("PUT", f"/_matrix/client/v3/rooms/{room}/send/m.room.message/setup-{time.time_ns()}", {
        "msgtype": "m.text", "body": body,
    }, token)
    # Tuwunel answers asynchronously
    for _ in range(10):
        time.sleep(1)
        messages = call("GET", f"/_matrix/client/v3/rooms/{room}/messages?dir=b&limit=10", token=token)
        for event in messages["chunk"]:
            if event["event_id"] == sent["event_id"]:
                break
            if event["type"] == "m.room.message" and event["sender"] != user_id:
                print(event["content"]["body"])
                return
    print("No reply yet; read the admin room in a Matrix client")


# Post the !admin appservices register command with the rendered descriptor
descriptor = open(f"{SHARED}/waldur-registration.yaml").read()
command(f"!admin appservices register\n```yaml\n{descriptor}\n```")

# Make the bot a homeserver admin, see below for why
bot = f"@{os.environ['WALDUR_MATRIX_BOT_LOCALPART']}:{server_name}"
command(f"!admin users make-user-admin {bot}")
EOF
unset ADMIN_PASSWORD
# Expect: Appservice registered with ID: waldur
# and a confirmation that @waldur-bot:<your-domain> is now an admin
```

The bot then becomes `@waldur-bot:<your-domain>` (`WALDUR_MATRIX_BOT_LOCALPART`) and can post on Waldur's behalf.

The register container, or the snippet's second command, makes the bot a homeserver admin. Waldur calls the homeserver's admin API as the bot: resetting a user's chat encryption from the drawer goes through `/_synapse/admin/v1/reset_password`, and a user deactivated in Waldur is locked on the homeserver the same way. Without admin rights the homeserver refuses those calls. Nothing makes the bot an admin by accident: Tuwunel runs with `grant_admin_to_first_user = false`, and the admin API is reachable only on the internal network. On a deployment registered before this step existed, the next `up` makes the bot an admin.

**From then on, whoever holds the appservice token is a homeserver admin.** The appservice token (`AS_TOKEN`) acts as the bot, so with it anyone can call the admin API, for example to reset any account's password and take it over. On Tuwunel, being a homeserver admin means being a member of `#admins:<your-domain>`, so `make-user-admin` joins the bot to that room. The bot itself answers commands only in Waldur's own rooms: admin-room traffic reaches its sync but triggers nothing. Anyone holding the appservice token, however, can post `!admin` commands there as the bot. The token is stored in three places: `secrets.env` and the rendered `waldur-registration.yaml` in the `waldur_matrix_secrets` volume, and Waldur's Constance settings in `waldur-db`, which database backups carry too. Restrict access to the volume, the database and its backups accordingly, and if the token may have been exposed, rotate it as described under [Token rotation](#token-rotation).

Admins are created through the shared-secret API, with `"admin": true`, as the register container and the snippet do. Tuwunel runs with `grant_admin_to_first_user = false`, so no account becomes an admin just by being the first one. Otherwise Waldur, which registers an account for whoever opens the chat first, could hand a user the homeserver's admin room. Once created, the admin can sign in to Element Web with that username and password.

On an existing deployment, `grant_admin_to_first_user = false` demotes nobody: whoever became admin as the first account stays one. Tuwunel treats every member of the admin room (`#admins:<WALDUR_DOMAIN>`) as an admin, so check its members in a Matrix client as the admin.

`/_synapse/admin/*` is not served through Caddy, which answers it with `404`; Waldur reaches the admin API on the internal network (`MATRIX_HOMESERVER_URL`).

## The Matrix bot

The `matrix` profile also starts `waldur-matrix-bot`, Waldur's member of every
Waldur room. It runs on a Matrix device of its own and holds that device's
keys, so it is the only process that can post into an encrypted room or read
the commands sent to it there. While it runs, every message Waldur sends as the
bot goes through it. It needs the appservice registered (above): until then it
restarts with a sign-in error. It also needs to be a homeserver admin (above)
for the drawer's encryption reset and for locking users deactivated in Waldur.

Run exactly one. It holds a lease in `waldur-db`, and a second one refuses to
start while the lease is held. Its keys live in `waldur-db` too (schema
`matrix_bot`), pickled under a key that is encrypted with Waldur's field
encryption key, so a database backup carries them and no volume is needed.

```bash
docker logs waldur-matrix-bot 2>&1 | grep "running on device"
```

Because its keys live in the database, a copy of that database carries the
bot's identity. Before starting a stack on a restored copy of another
deployment's database (a staging copy of production, say), leave out the
`matrix` profile or drop the copy's `matrix_bot` schema and
`matrix_chat_matrixbotidentity` rows. Otherwise a second bot runs as the same
device, can read the original's rooms, and corrupts both bots' sessions.

## Enabling the homeport UI

Backend access to Matrix is gated by the `MATRIX_ENABLED` Constance flag. `waldur-matrix-init` turns it on the first time; switched off in Waldur, it stays off across later `up` runs. The homeport UI is gated separately by a feature flag — enable it once via the `load_features` management command:

```bash
docker exec waldur-mastermind-worker bash -c \
  'echo "{\"project.show_matrix_chat\": true}" > /tmp/features.json && waldur load_features /tmp/features.json'
```

After a hard reload (Cmd-Shift-R / Ctrl-Shift-R), project views show the **Communication** tab — but only after a Matrix room has been created for that project (the tab is gated by `hasActiveProjectMatrixRoomInCache`). Until then, the room-creation entry point lives at `Manage → Chat` (`?tab=chat` query parameter — direct paths like `/manage/chat/` return 404).

## Token rotation

To rotate the AS/HS tokens (e.g., after credential exposure), replace both in the
secrets volume and bring the profile up again. Always both, since either may have
leaked.

```bash
docker compose --profile matrix run --rm --no-deps --entrypoint sh waldur-matrix-init-volume -c '
  sed -i -e "s/^AS_TOKEN=.*/AS_TOKEN=$(openssl rand -hex 32)/" \
         -e "s/^HS_TOKEN=.*/HS_TOKEN=$(openssl rand -hex 32)/" \
         /var/lib/waldur/matrix/secrets.env'
docker compose --profile matrix up -d
docker wait waldur-matrix-register
docker logs waldur-matrix-register
# Expect: Appservice 'waldur' was registered with other tokens, another URL or other namespaces; replaced it with Waldur's.
```

`waldur-matrix-init` seeds the new tokens into Constance, and
`waldur-matrix-register` signs in as `@waldur-bootstrap`, unregisters the old
registration and registers the new one. Tuwunel does not replace a registration
that is registered again under the same id, which is why the old one is removed
first. The container fails if the homeserver still rejects the new token.

Chat is down from the moment init seeds the new tokens until the register
container finishes, usually tens of seconds. Events sent in that window, such as
a bot command, are not delivered to Waldur. The registration token and the room
database in `tuwunel_data` are untouched, so existing users and rooms survive.

Do not delete the secrets volume to rotate: that also replaces `BOOTSTRAP_PASSWORD`,
which then no longer matches `@waldur-bootstrap` on the homeserver, and
registration fails.

### Rotating with password login off

With `WALDUR_MATRIX_LOGIN_WITH_PASSWORD=false`, as with single sign-on, the
bootstrap admin cannot sign in. An `up` with working tokens then cannot read
the homeserver's copy of the registration, so it only warns and changes
nothing, and a rotation fails after init has seeded the new tokens, with
"Password login is disabled on the homeserver". Run the register container once
more with a homeserver admin's access token on its standard input. Passed this
way, the token lands in no container's environment, where `docker inspect`
would show it, and the one-off container is removed when it exits.

The commands below create a temporary admin through the shared-secret API in a
Waldur container, which reaches the homeserver and holds the registration token
in Constance, so neither the registration token nor the admin's token passes
through a command line. They register with that admin's token and then have
the admin deactivate itself:

```bash
TOKEN=$(docker exec waldur-mastermind-worker waldur shell -c '
import hashlib, hmac, secrets, httpx
from constance import config
user, password = "rotation-" + secrets.token_hex(4), secrets.token_hex(32)
homeserver = httpx.Client(base_url=config.MATRIX_HOMESERVER_URL)
nonce = homeserver.get("/_synapse/admin/v1/register").raise_for_status().json()["nonce"]
mac = hmac.new(config.MATRIX_USER_REGISTRATION_SECRET.encode(),
               "\0".join([nonce, user, password, "admin"]).encode(), hashlib.sha1)
print(homeserver.post("/_synapse/admin/v1/register", json={
    "nonce": nonce, "username": user, "password": password, "admin": True,
    "mac": mac.hexdigest()}).raise_for_status().json()["access_token"])
' | tail -n 1)

printf '%s\n' "$TOKEN" | docker compose --profile matrix run --rm --no-deps -T \
  waldur-matrix-register /etc/waldur/matrix/register-matrix.sh --admin-token-stdin

printf '%s\n' "$TOKEN" | docker exec -i waldur-mastermind-worker python3 -c '
import json, sys, time, urllib.error, urllib.parse, urllib.request
token = sys.stdin.readline().strip()
def call(method, path, body=None):
    request = urllib.request.Request("http://tuwunel.internal:6167" + path,
        None if body is None else json.dumps(body).encode(),
        {"Authorization": "Bearer " + token, "Content-Type": "application/json"}, method=method)
    with urllib.request.urlopen(request) as response:
        return json.load(response)
user_id = call("GET", "/_matrix/client/v3/account/whoami")["user_id"]
alias = urllib.parse.quote("#admins:" + user_id.split(":", 1)[1])
room = urllib.parse.quote(call("GET", f"/_matrix/client/v3/directory/room/{alias}")["room_id"])
call("PUT", f"/_matrix/client/v3/rooms/{room}/send/m.room.message/deactivate-{time.time_ns()}",
     {"msgtype": "m.text", "body": f"!admin users deactivate {user_id}"})
for _ in range(10):
    time.sleep(1)
    try:
        call("GET", "/_matrix/client/v3/account/whoami")
    except urllib.error.HTTPError:
        sys.exit(print(f"{user_id} deactivated"))
sys.exit(f"{user_id} is still active; deactivate it from #admins by hand")
'
unset TOKEN
```

Deactivating the temporary admin also signs it out, and nobody can sign in to
the account again, not even through single sign-on.

The same `run` with an admin's token applies any other change the bootstrap
admin cannot read with password login off, such as a new
`WALDUR_MATRIX_APPSERVICE_URL`.

## Token lifetimes

Waldur's chat drawer signs in with a refresh token, so its access tokens expire after `access_token_ttl` (300 seconds) and are renewed in the background; a page left silent for `refresh_token_ttl` (86400 seconds, idle), e.g. on a suspended laptop, starts a new session through Waldur. Clients that sign in without a refresh token, such as Element with a password, keep non-expiring tokens. To change the lifetimes, edit `config/matrix/tuwunel.toml.template`; `access_token_ttl` must be positive, as Tuwunel reads `0` as "expire immediately".

Tuwunel reads its configuration only at startup, and `tuwunel.toml` is rendered from the template only when `waldur-matrix-init` runs, on `up`. After upgrading or editing the template, re-render it and restart Tuwunel, which an `up` leaves running with the old values:

```bash
docker compose --profile matrix up -d
docker compose restart tuwunel
```

## Single sign-on for Matrix clients

With Waldur's `MATRIX_EXTERNAL_LOGIN_METHOD` set to `oidc`, users sign in to
Element or another Matrix client through the same identity provider (IdP) as
Waldur, into the account Waldur provisioned for them.
[Single sign-on for Matrix clients](https://docs.waldur.com/latest/developer-guide/admin-guide/matrix-sso/)
explains how the accounts line up and why the homeserver is configured this
way; this section covers the compose settings.

Register a client at the IdP with the redirect URI
`https://<WALDUR_DOMAIN>/_matrix/client/unstable/login/sso/callback/<client id>`,
then set in `.env`:

```bash
WALDUR_MATRIX_LOGIN_WITH_PASSWORD=false
WALDUR_MATRIX_SSO_ENABLED=true
WALDUR_MATRIX_SSO_NAME=Example SSO
WALDUR_MATRIX_SSO_BRAND=keycloak
WALDUR_MATRIX_SSO_ISSUER_URL=https://keycloak.example.org/realms/waldur
WALDUR_MATRIX_SSO_CLIENT_ID=matrix-homeserver
WALDUR_MATRIX_SSO_CLIENT_SECRET=<secret>
WALDUR_MATRIX_SSO_USERID_CLAIM=sub
WALDUR_MATRIX_SSO_FORBIDDEN_USERNAMES=matrix-admin
WALDUR_MATRIX_SSO_REGISTRATION_METHOD=keycloak
```

and run `docker compose --profile matrix up -d`, which re-renders the homeserver
configuration and recreates `tuwunel`. After changing only
`WALDUR_MATRIX_SSO_CLIENT_SECRET`, also run `docker compose restart tuwunel`.

With single sign-on on, `waldur-matrix-init` also seeds Waldur's
`MATRIX_EXTERNAL_LOGIN_METHOD` as `oidc` and `MATRIX_SSO_REGISTRATION_METHOD`
from `WALDUR_MATRIX_SSO_REGISTRATION_METHOD`: the name of the Waldur identity
provider this IdP is, such as `keycloak`. Waldur gives a Matrix account only to
users who signed up through that provider. Both are seeded on every `up`, so
while single sign-on is on, a method changed in Administration goes back to
`oidc`. With single sign-on off it seeds neither, so a method set under
**Administration → Configuration → Matrix chat → Settings** stays as it is.

`waldur-matrix-init` writes the client secret to `sso_client_secret` in the
secrets volume, not into `tuwunel.toml`. It checks the settings before it
renders anything, and a refused run keeps the previous configuration. It
refuses a missing issuer, client ID, secret or registration method, a `WALDUR_MATRIX_SSO_ENABLED`
other than `true` or `false`, a name with quotes, backslashes or control
characters, a client ID or brand with anything but letters, digits, `.`, `_`
and `-`, an issuer that is not an `https://` URL, and an unrecognised claim.
It also refuses single sign-on together with
`WALDUR_MATRIX_OPEN_REGISTRATION=true`: with `trusted`, anyone could register
`@bob` first and receive bob's SSO login. The homeserver is configured so SSO
lands in Waldur's account:

- `name` is `WALDUR_MATRIX_SSO_NAME`, the label of the login button.
  `brand` is `WALDUR_MATRIX_SSO_BRAND`, the kind of IdP (`keycloak`, `github`,
  `gitlab`, `google`, `mas`), from which Tuwunel takes provider-specific
  defaults and workarounds.
- `issuer_url` must be what the IdP publishes as `issuer` in its discovery
  document. Tuwunel fetches that document from inside its container at the
  first SSO login, not at startup, so the issuer must resolve there and present
  a certificate trusted there. The bundled Keycloak (`--profile keycloak`,
  `https://<WALDUR_DOMAIN>/auth/realms/<realm>`) works only with a
  `WALDUR_DOMAIN` that resolves to the host from inside containers and a
  certificate from a public CA, not `TLS=internal`.
- `userid_claims` is `WALDUR_MATRIX_SSO_USERID_CLAIM`, one of `sub`,
  `preferred_username`, `username`, `nickname`, `email` (its local part) or
  `login` (GitHub). `email` is refused unless
  `WALDUR_MATRIX_SSO_ALLOW_EMAIL_CLAIM=true`: only the local part is used, so
  `alice@a.org` and `alice@b.org` would sign in to the same account; set it
  only if the IdP issues addresses of a single domain. It must be the claim Waldur's identity provider uses as
  `user_claim`, with that provider's `user_field` left at `username` and
  `MATRIX_USER_ID_FORMAT=username`, and its values must already be valid
  Matrix localparts (lowercase letters, digits, `. _ - / +`). Users with a
  `+` whom Waldur provisioned before it kept `+` in localparts still have `_`
  instead, so SSO cannot reach their account.
- `trusted = true` signs in to the existing account that matches the claim, and
  that is *any* existing account with that name, so keep `sub` unless the IdP
  controls usernames. Without it, Tuwunel refuses the login: it signs in only
  to accounts it created through SSO, and Waldur provisioned these.
- `registration = false`: SSO creates no accounts and only signs in to
  existing ones, with `trusted` any whose name matches the claim, hence
  `forbidden_usernames`.
- `forbidden_usernames` closes accounts that are not a Waldur user's to SSO.
  The bot's localpart (`WALDUR_MATRIX_BOT_LOCALPART`) and `waldur-bootstrap`,
  reserved for the bootstrap admin that automatic registration will create,
  are on it automatically. Create any other homeserver admin under a localpart
  no IdP user can hold, such as `matrix-admin`, and list it in
  `WALDUR_MATRIX_SSO_FORBIDDEN_USERNAMES` (comma-separated). Admins on the list
  can still be created through the shared-secret registration API; SSO cannot
  sign in to them. Tuwunel logs a warning at startup for each existing
  account on the list; that is expected.

`WALDUR_MATRIX_LOGIN_WITH_PASSWORD=false` removes the password form from
clients; Waldur's chat drawer signs in through the appservice and is
unaffected. It applies to every account, so the admin created with a password
in the [appservice registration](#appservice-registration) cannot sign in to a
client either. Rotation does not need it: see
[Rotating with password login off](#rotating-with-password-login-off).

## Calls

With `WALDUR_MATRIX_RTC_ENABLED=true`, the homeserver's `.well-known/matrix/client` advertises one call focus (`org.matrix.msc4143.rtc_foci`), pointing at Waldur's own API:

```json
{"type": "livekit", "livekit_service_url": "https://${WALDUR_DOMAIN}/api/matrix/livekit"}
```

Element (Web, Desktop and mobile, through Element Call) and Waldur's chat drawer both read it and ask Waldur for a LiveKit token: `POST /api/matrix/livekit/get_token`, or the legacy `/api/matrix/livekit/sfu/get` that Element Call falls back to. Waldur verifies the caller's Matrix OpenID token with the homeserver at `http://tuwunel.internal:6167`, checks that the caller is joined to the room now and that the device is theirs, and answers with `wss://${WALDUR_DOMAIN}/livekit` and a token for that room only. Anyone else gets `403`.

`waldur-matrix-init` seeds the settings Waldur needs on every `up`: `MATRIX_LIVEKIT_PUBLIC_URL` (`wss://${WALDUR_DOMAIN}/livekit`), `MATRIX_LIVEKIT_URL` (`http://livekit.internal:7880`, the room API on the Compose network) and `MATRIX_LIVEKIT_KEY` / `MATRIX_LIVEKIT_SECRET` (from `WALDUR_LIVEKIT_KEY` / `WALDUR_LIVEKIT_SECRET`). Caddy routes only LiveKit's signaling under `/livekit/`: its room API (`/livekit/twirp/`) answers `404` from outside, since Waldur reaches it on the Compose network.

Element calls these endpoints from another origin. Waldur answers them with `Access-Control-Allow-Origin: *` and no credentials, and the `Caddyfile` keeps its site-wide CORS headers (the request's origin plus credentials) off `/api/matrix/livekit/`, so the two never collide.

The OpenID check goes to the homeserver on the internal network, so calls work with `WALDUR_DOMAIN=localhost` and do not need Tuwunel's federation.

### Upgrading from lk-jwt-service

Earlier versions of this stack ran `lk-jwt-service` behind `/lk-jwt/` to issue call tokens. Waldur issues them now, and the service and its route are gone:

1. Pull this version and remove `WALDUR_LK_JWT_IMAGE_TAG` from `.env`.
2. Use a Waldur image that serves `/api/matrix/livekit` (`WALDUR_MASTERMIND_IMAGE_TAG`).
3. Re-render the homeserver config and restart Tuwunel so `.well-known` points at Waldur, and remove the old container:

   ```bash
   docker compose --profile matrix --profile matrix-rtc up -d --remove-orphans
   docker compose restart tuwunel
   ```

4. Reload Element or the Waldur page; clients read the new focus from `.well-known`. Calls already running keep their LiveKit connection.

## LiveKit / voice & video notes

`WALDUR_LIVEKIT_NODE_IP` advertises the host's RTC media address to clients. The default `127.0.0.1` is correct for a local demo only — for any reachable deployment, set this to the host's external IP or DNS name so remote clients can connect. The RTC media ports (`WALDUR_MATRIX_RTC_TCP_PORT`/`UDP_PORT`, default 7881/7882) must also be reachable from clients.

`WALDUR_LIVEKIT_KEY` / `WALDUR_LIVEKIT_SECRET` default to development values. Anyone who knows them can mint a token for any call, so **override both** for anything beyond a local demo, with a secret of at least 32 characters. With `--profile matrix-rtc` and a `WALDUR_DOMAIN` other than `localhost` or `host.docker.internal`, the one-shot `livekit-credentials-check` refuses the development values or a shorter secret, and `docker compose up -d` fails with `service "livekit-credentials-check" didn't complete successfully`. `livekit`, which waits for the check, does not start. The failed command can also leave other services unstarted: on a first start, or after `docker compose down`, the API, the workers, HomePort, Caddy and the homeserver stay down, so Waldur itself is down, not only calls, while the database migration may still have run. Services that were running and that this `up` does not change keep running. Set `WALDUR_LIVEKIT_KEY` and `WALDUR_LIVEKIT_SECRET` in `.env`, or turn calls off again (`WALDUR_MATRIX_RTC_ENABLED=false` and no `--profile matrix-rtc`), and run `up -d` again.

### TURN relay (symmetric NAT / iCloud Private Relay)

Direct media to `WALDUR_LIVEKIT_NODE_IP` fails for clients behind symmetric NAT or proxies that don't carry WebRTC UDP. Enabling TURN gives LiveKit a relay those clients fall back to.

Set `WALDUR_MATRIX_TURN_ENABLED=true` (within `--profile matrix-rtc`). The stack uses **TURN/UDP on port 443** — `udp_port` is the port LiveKit advertises to clients, and 443 is the firewall-friendly choice. Because the stack is single-host, the relay lives at `WALDUR_DOMAIN:443/udp` — the same IP that already serves the web UI, so **no extra DNS record is needed**.

This mode needs **no certificate**: TURN/UDP isn't TLS, so there is nothing to provision or renew. It also doesn't collide with Caddy — Caddy binds `443/tcp` (HTTPS) while TURN takes `443/udp`, which is otherwise free on the host.

Open **`443/udp`** on any upstream firewall / cloud security group (the same way `443/tcp` is already opened for the web UI).

```bash
# Confirm livekit is listening on 443/udp inside the container
docker compose exec livekit sh -c 'ss -lun | grep :443 || netstat -lun | grep :443'
```

Coverage note: TURN/UDP rescues symmetric-NAT clients and any network that permits outbound UDP on 443. It does **not** help clients on networks that block all outbound UDP (strict corporate firewalls) — that requires TURN/TLS on TCP 443, which on a single host means giving LiveKit its own IP or a layer-4 load balancer (the helm topology). For a single-host compose deployment, TURN/UDP is the pragmatic option.

## Monitoring

The stack runs neither the metrics exporter nor Prometheus. To watch chat
health from outside Waldur, run
[waldur-prometheus-exporter](https://github.com/waldur/waldur-prometheus-exporter)
next to the stack and load the rules below into your Prometheus.

The exporter calls Waldur's Matrix diagnostics,
`GET /api/admin/matrix/diagnostics/`, about every two minutes and publishes:

| Metric | Labels | Value |
| --- | --- | --- |
| `waldur_matrix_diagnostics_up` | | `1` if the last diagnostics call succeeded, `0` if it failed |
| `waldur_matrix_check_passed` | `check` | `1` if the diagnostics check passed, `0` if not, e.g. `homeserver_reachable`, `bot_running`, `bot_whoami`, `appservice_ping` |
| `waldur_matrix_rooms` | `state` | Rooms per state: `creating`, `active`, `disabling`, `archived`, `error` |

The exporter needs the API token of a support or staff user. If every call
gets `403`, the token belongs to neither, or Waldur is too old to let support
users read diagnostics and needs a staff user's token;
`waldur_matrix_diagnostics_up` then stays `0`.

### Running the exporter

Put the exporter in a `docker-compose.override.yml` next to
`docker-compose.yml`, which `docker compose` reads unless `-f` names the files,
and set `WALDUR_METRICS_EXPORTER_TOKEN` in `.env` to the API token of a
support or staff user:

```yaml
services:
  waldur-metrics-exporter:
    container_name: waldur-metrics-exporter
    image: '${DOCKER_REGISTRY_PREFIX}opennode/waldur-prometheus-exporter:${WALDUR_MASTERMIND_IMAGE_TAG}'
    environment:
      # The API's address inside the stack, as the appservice uses it.
      - WALDUR_API_URL=http://waldur-mastermind-api:8080/api/
      - WALDUR_API_TOKEN=${WALDUR_METRICS_EXPORTER_TOKEN}
    ports:
      # Where your Prometheus scrapes /metrics; widen the address if it runs
      # on another host.
      - '127.0.0.1:9180:8080'
    restart: always
```

Then have Prometheus scrape it and load the [alert rules](#alert-rules) below,
saved as `matrix-chat-alerts.yml` next to `prometheus.yml`:

```yaml
rule_files:
  - matrix-chat-alerts.yml
scrape_configs:
  - job_name: waldur-metrics-exporter
    scrape_interval: 60s
    static_configs:
      - targets: ['<docker host>:9180']
```

### Alert rules

The same rules ship with the Helm chart as a `PrometheusRule`:

<!-- Copied from waldur-helm's waldur/files/matrix-chat-alerts.yaml: change both together. -->

```yaml
groups:
  - name: waldur-matrix-chat
    rules:
      # One series per Waldur, not per scrape target. On Kubernetes, where a
      # target has a namespace label, a Waldur is a namespace and job: a
      # replaced exporter pod is a new target, with another instance and other
      # pod, node or chart version labels. Held per target, its predecessor's
      # last value would stay beside the new pod's live one for 20 minutes,
      # firing for a check that has recovered, and an alert would resolve and
      # start over under the new labels. Elsewhere a target is a Waldur and
      # keeps its labels, so several Waldurs in one job stay apart.
      - record: waldur_matrix_check_passed:per_waldur
        expr: >-
          min by (namespace, job, check) (waldur_matrix_check_passed{namespace!=""})
          or
          waldur_matrix_check_passed{namespace=""}
      - record: waldur_matrix_rooms:per_waldur
        expr: >-
          max by (namespace, job, state) (waldur_matrix_rooms{namespace!=""})
          or
          waldur_matrix_rooms{namespace=""}
      # The exporter drops every check and room series when a diagnostics
      # call fails, and Prometheus drops them while the exporter is down or
      # restarting. Holding the last value for 20 minutes keeps that from
      # resolving an alert or restarting its "for"; DiagnosticsDown and
      # MetricsMissing fire before the hold runs out.
      - record: waldur_matrix_check_passed:last20m
        expr: >-
          waldur_matrix_check_passed:per_waldur
          or
          last_over_time(waldur_matrix_check_passed:per_waldur[20m])
      - record: waldur_matrix_rooms:last20m
        expr: >-
          waldur_matrix_rooms:per_waldur
          or
          last_over_time(waldur_matrix_rooms:per_waldur[20m])
      - alert: WaldurMatrixMetricsMissing
        expr: absent(waldur_matrix_diagnostics_up)
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: No Matrix chat metrics from the Waldur metrics exporter
          description: >-
            Prometheus has no waldur_matrix_diagnostics_up series: the metrics
            exporter is down, is not scraped, or is a version without Matrix
            metrics. None of the other Matrix chat alerts can fire until it is.
      - alert: WaldurMatrixDiagnosticsDown
        expr: waldur_matrix_diagnostics_up == 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: The metrics exporter cannot read Waldur's Matrix diagnostics
          description: >-
            GET /api/admin/matrix/diagnostics/ has failed for 10 minutes, so the
            Matrix chat checks are not updated. The exporter's token must belong
            to a support or staff user: a 403 means it belongs to neither, or
            that Waldur is too old to let support users read diagnostics.
      # Diagnostics answers for a Waldur without Matrix chat too, with these
      # checks failing. This alert and BotNotRunning stay quiet where no
      # homeserver URL is set, so such a Waldur on the same Prometheus does not
      # raise them; the sign-in and ping alerts are quiet there already.
      - alert: WaldurMatrixHomeserverUnreachable
        expr: >-
          waldur_matrix_check_passed:last20m{check="homeserver_reachable"} == 0
          unless ignoring(check)
          waldur_matrix_check_passed:last20m{check="homeserver_configured"} == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: Waldur cannot reach the Matrix homeserver
          description: >-
            Waldur's backend has not reached the homeserver at
            MATRIX_HOMESERVER_URL for 5 minutes, so chat is down for everyone.
            The bot sign-in and appservice ping alerts stay quiet while it
            fires: both checks fail with it.
      - alert: WaldurMatrixBotNotRunning
        expr: >-
          waldur_matrix_check_passed:last20m{check="bot_running"} == 0
          unless ignoring(check)
          waldur_matrix_check_passed:last20m{check="homeserver_configured"} == 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: The Matrix bot is not running
          description: >-
            No matrix_bot process has held the bot's lease for 10 minutes.
            Messages Waldur posts in rooms wait in the outbox and chat commands
            get no answer until the bot runs again.
      - alert: WaldurMatrixBotSignInFailing
        expr: >-
          waldur_matrix_check_passed:last20m{check="bot_whoami"} == 0
          unless ignoring(check)
          waldur_matrix_check_passed:last20m{check="homeserver_reachable"} == 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: The homeserver does not accept Waldur's appservice token
          description: >-
            The homeserver has rejected the bot's whoami call for 10 minutes:
            the appservice is not registered, or is registered with other
            tokens. Waldur cannot create rooms or accounts until it is fixed.
      - alert: WaldurMatrixAppservicePingFailing
        expr: >-
          waldur_matrix_check_passed:last20m{check="appservice_ping"} == 0
          unless ignoring(check)
          waldur_matrix_check_passed:last20m{check="bot_whoami"} == 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: The homeserver cannot reach Waldur's appservice endpoint
          description: >-
            The appservice ping has failed for 10 minutes. The homeserver
            cannot deliver room events to Waldur, so membership and messages
            Waldur reacts to are not processed.
      - alert: WaldurMatrixRoomsErred
        expr: waldur_matrix_rooms:last20m{state="error"} > 0
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: Matrix rooms are stuck in the error state
          description: >-
            {{ $value }} Matrix room(s) have been in the error state for
            30 minutes. Waldur does not retry them on its own.
```

The rules match the metrics of every Waldur the Prometheus scrapes. A stack
that never ran the `matrix` profile raises no alert among them: the endpoint
answers there too, its diagnostics report that no homeserver URL is set, and
the alerts stay quiet where that is so. One that ran the profile and no longer
does still has `MATRIX_HOMESERVER_URL` set, and keeps raising the homeserver
and bot alerts. The other side of it: if that setting is emptied on a stack
that has chat, its four check alerts fall silent.
`WaldurMatrixMetricsMissing` fires only when no exporter at all publishes
Matrix metrics, so with several it does not notice one of them going away.

| Alert | Fires when | Severity | First thing to check |
| --- | --- | --- | --- |
| `WaldurMatrixMetricsMissing` | No `waldur_matrix_diagnostics_up` series for 15 minutes | warning | `docker logs waldur-metrics-exporter`, that the image is a version with Matrix metrics, and that Prometheus lists the exporter as a target. |
| `WaldurMatrixDiagnosticsDown` | The diagnostics call failed for 10 minutes | warning | `docker logs waldur-metrics-exporter`. `403` means the token belongs to neither a support nor a staff user, or Waldur is too old to let support users read diagnostics; anything else, `docker logs waldur-mastermind-api`. |
| `WaldurMatrixHomeserverUnreachable` | `homeserver_reachable` failed for 5 minutes while a homeserver URL is set | critical | `docker logs tuwunel`. A `tuwunel` container that is up but not answering after a tag change is migrating its database: do not restart it, see [Pinned image tags](#pinned-image-tags). |
| `WaldurMatrixBotNotRunning` | `bot_running` failed for 10 minutes while a homeserver URL is set | warning | `docker logs waldur-matrix-bot`, see [The Matrix bot](#the-matrix-bot). |
| `WaldurMatrixBotSignInFailing` | `bot_whoami` failed for 10 minutes while the homeserver is reachable | warning | The appservice registration: `docker logs waldur-matrix-register`, and [Token rotation](#token-rotation) if the tokens changed. |
| `WaldurMatrixAppservicePingFailing` | `appservice_ping` failed for 10 minutes while `bot_whoami` passes | warning | That `tuwunel` can reach the API at the registered URL (`http://waldur-mastermind-api:8080` unless `WALDUR_MATRIX_APPSERVICE_URL` changes it), and `docker logs waldur-mastermind-api` for `DisallowedHost`. |
| `WaldurMatrixRoomsErred` | At least one room in the `error` state for 30 minutes | warning | `GET /api/matrix/rooms/?state=error` lists them with their `error_message`. Fix the cause, then retry each room as staff with `POST /api/matrix/rooms/<uuid>/retry/`. |

When the homeserver is unreachable, the bot's whoami and the appservice ping
fail with it, so their alerts stay quiet while
`WaldurMatrixHomeserverUnreachable` fires. Waldur skips the ping when whoami
fails, so the ping alert also stays quiet while `WaldurMatrixBotSignInFailing`
fires.

The alerts read the `:last20m` series the same rules record, which keep each
check's and room count's last value for 20 minutes, so a brief exporter or
Prometheus restart neither resolves a real alert nor starts its timer over.
They are recorded per Waldur. Outside Kubernetes each scrape target is a
Waldur, so several stacks can be targets of the one job above and keep their
alerts apart.

The thresholds follow the exporter's two-minute refresh: 5 minutes is two or
three failed refreshes in a row and 10 minutes about five, which rides out a
container restart. Waldur never retries an erred room on its own, so
`WaldurMatrixRoomsErred` keeps firing until staff retry the rooms; the
30 minutes give staff already handling an outage time to do that first.

## Apple Silicon

The Matrix component images already publish `linux/arm64`. The Waldur images may need a local arm64 rebuild because of `openportal`'s native dependency:

```bash
cd ../waldur-mastermind && docker build -t opennode/waldur-mastermind:local-arm .
cd ../waldur-homeport && docker build -t opennode/waldur-homeport:local-arm .
```

Then in `.env`: `WALDUR_MASTERMIND_IMAGE_TAG=local-arm`, `WALDUR_HOMEPORT_IMAGE_TAG=local-arm`, `DOCKER_REGISTRY_PREFIX=`. See the existing "Apple Silicon caveats" guidance for QEMU fallback details.

## Verifying the add-on

End-to-end smoke after `docker compose --profile matrix up -d`:

```bash
# 1. Caddy serves the homeserver via the Matrix routes (proxied to tuwunel:6167)
curl -k https://localhost/_matrix/client/versions
curl -k https://localhost/.well-known/matrix/client
curl -k https://localhost/.well-known/matrix/server

# 2. Constance values were seeded (run inside the mastermind container)
docker exec waldur-mastermind-worker waldur shell -c \
  "from constance import config; print(config.MATRIX_ENABLED, config.MATRIX_HOMESERVER_URL, config.MATRIX_HOMESERVER_DOMAIN)"
# expect: True http://tuwunel.internal:6167 localhost
```

Once `waldur-matrix-register` has registered the appservice (see Appservice registration above), visit `https://${WALDUR_DOMAIN}/projects/<uuid>/manage/?tab=chat` as a staff user and click **Create chat room**. The Manage tabs use query-param URLs (`?tab=chat`), not path segments — direct paths like `/manage/chat/` 404.

Until the appservice is registered, room creation fails with `M_UNKNOWN_TOKEN` in `docker compose logs waldur-mastermind-worker`. Check `docker logs waldur-matrix-register` for why it is not.

## Troubleshooting

- **`waldur-matrix-init` fails and Tuwunel does not start**: read `docker logs waldur-matrix-init`. `init_matrix_settings` refuses appservice tokens in Constance that no deployment seeded, for example from an earlier run of the Setup wizard, and writes nothing. To hand the tokens to compose, clear `MATRIX_APPSERVICE_AS_TOKEN` and `MATRIX_APPSERVICE_HS_TOKEN` under **Administration → Configuration → Matrix chat → Settings**, and `up` again; otherwise start from a fresh stack.
- **`M_UNKNOWN_TOKEN` in worker logs after a token rotation**: the homeserver still holds the registration with the old tokens. Check `docker logs waldur-matrix-register` and see [Token rotation](#token-rotation). Registering the descriptor again by hand does not fix it on its own: Tuwunel keeps the old tokens for an id it already has, so unregister first.
- **Webhook `DisallowedHost` errors**: the appservice descriptor is rendered with `url: http://waldur-mastermind-api:8080` (the Compose service name), which is in `ALLOWED_HOSTS` for the dockerised settings. If you change the URL — for example to call back via an external hostname — patch `ALLOWED_HOSTS` in `config/waldur-mastermind/override.conf.py`.
- **Chat drawer says encryption is unavailable in this browser**: the browser refused the encryption WebAssembly. The homeport `Content-Security-Policy` in the `Caddyfile` must keep `'wasm-unsafe-eval'` in `script-src`; it allows compiling WebAssembly only, not `eval()` of JavaScript. A Caddyfile customized before this was added needs it added by hand.
- **Browser chat drawer fails to connect**: the backend talks to Tuwunel internally at `http://tuwunel.internal:6167` (Docker DNS); the browser must reach Tuwunel through Caddy at `https://${WALDUR_DOMAIN}`. `waldur-matrix-init` seeds both — backend uses `MATRIX_HOMESERVER_URL`, browser-facing endpoints serve `MATRIX_HOMESERVER_PUBLIC_URL` (requires `waldur-mastermind` >= 8.x with the dual-URL split). If the chat drawer logs CSP errors connecting to `tuwunel.internal`, verify `MATRIX_HOMESERVER_PUBLIC_URL` is set: `docker exec waldur-mastermind-worker waldur shell -c "from constance import config; print(config.MATRIX_HOMESERVER_PUBLIC_URL)"`.
- **A call shows "Could not connect to the call."**: confirm `--profile matrix-rtc` is active and `WALDUR_MATRIX_RTC_ENABLED=true`, then check the call token request to `https://${WALDUR_DOMAIN}/api/matrix/livekit/…` in the browser's network tab and `docker compose logs waldur-mastermind-api`. `403` means Waldur refused the caller (not joined to the room, or an unknown device). `503` means Waldur could not reach the homeserver or LiveKit, or the LiveKit settings are missing: check that `waldur-matrix-init` ran with RTC enabled. A request still going to `/lk-jwt/…` means the homeserver serves an old `.well-known`: restart `tuwunel` (see [Upgrading from lk-jwt-service](#upgrading-from-lk-jwt-service)).
- **Diagnostics shows "Public homeserver reachable" as FAIL even though the chat works**: the reachability probe at `/api/admin/matrix/diagnostics/` runs from inside the mastermind container. The public URL (`https://${WALDUR_DOMAIN}`) is a Caddy-proxied address reachable from the browser, not from the backend's network namespace — so the probe gets `Connection refused`. The "Public homeserver URL configured" check above it confirms the value is set; verify the chat round-trips end-to-end from a browser instead of trusting this single probe.
- **Communication tab missing on a project**: requires three things — the `project.show_matrix_chat` feature flag is on, a Matrix room exists for the project, AND the room cache has populated. The third only happens after the project view is visited at least once in the current session. If you navigate directly to `/projects/<uuid>/communication/` and get 404, visit `/projects/<uuid>/` first, then the tab appears in the nav.
