# Matrix chat with Docker Compose

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

Put the profiles in `.env` as well: `COMPOSE_PROFILES=matrix`, or `COMPOSE_PROFILES=matrix,matrix-rtc` with calls. Every `docker compose` command then includes the add-on, the plain commands in the README's upgrade included. Without it, a command without `--profile` leaves the Matrix services out: `pull` and `up -d` neither update nor start them, so after an upgrade the bot is not updated and `waldur-matrix-init` and `waldur-matrix-register` do not run. A `--profile` flag replaces `COMPOSE_PROFILES` for that one command, so the commands below that pass only `--profile matrix` leave LiveKit as it is.

The add-on runs `waldur init_matrix_settings` and `waldur register_matrix_appservice` from the mastermind image, so it needs `WALDUR_MASTERMIND_IMAGE_TAG` at the version `.env.example` pins or newer. With an older image `waldur-matrix-init` fails on the unknown command and Tuwunel never starts.

## Pinned image tags

Matrix component versions live in `.env`. Bump them deliberately:

| Variable | Default | Component |
|---|---|---|
| `WALDUR_TUWUNEL_IMAGE_TAG` | `v1.9.3` | Tuwunel homeserver — requires 1.7.0+ for Synapse-compatible `registration_shared_secret`. **Kept in lockstep with the Helm chart's `matrixChat.homeserver.imageTag`** — one supported homeserver version across both packaging paths |
| `WALDUR_LIVEKIT_IMAGE_TAG` | `v1.13.7` | LiveKit SFU |

Both publish multi-arch (`linux/amd64` and `linux/arm64`) manifests for the pinned tags. Re-check with `docker buildx imagetools inspect <image>:<tag>` after bumps.

A tag can be moved to another image; a digest cannot. Either variable also takes `<tag>@sha256:<digest>` to pin the image itself. Two other images the add-on depends on are moving tags: `caddy:2`, which serves `/_matrix`, and `postgres:${WALDUR_POSTGRES_IMAGE_TAG}` (`16`), which holds Waldur's database, the bot's keys included.

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
restoring that backup is the only rollback (see
[Backup and restore](#backup-and-restore)). The Helm chart's
[Matrix chat guide](https://docs.waldur.com/latest/admin-guide/deployment/helm/docs/matrix-chat/)
has the upgrade and CVE-response procedure, which applies to both packaging
paths.

**`WALDUR_DOMAIN` is frozen once the homeserver has data.** It is the Matrix
`server_name`, baked into every user and room ID. The homeserver also stamps
it into the database on first boot and refuses to start under a different
name:

```text
Critical error starting server: Database belongs to old.example; configured server name is new.example. Cannot reuse.
```

That is not a bug to work around by wiping `tuwunel_data` — wiping it discards
the whole chat corpus. Changing the domain means a fresh homeserver.

**Never run `docker compose down -v` with the `matrix` profile active.** It
deletes the `tuwunel_data` and `waldur_matrix_secrets` volumes, with every
message and the tokens, but not Waldur's database, which lives in the
`./pgsql` bind mount. Waldur is then left with rooms, accounts and a bot
device that the homeserver no longer has, and the next `up` generates new
tokens.

## Appservice registration

This stack registers the appservice through Tuwunel's `!admin appservices register` admin-room command; Tuwunel can also read registrations from its config file, which the stack does not use. This is handled for you: the one-shot `waldur-matrix-register` container runs after the homeserver comes up, drives that admin-room command and makes the bot a homeserver admin (see below). There is nothing to paste.

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

### Registering by hand

Set `WALDUR_MATRIX_REGISTER_APPSERVICE=false` to keep registration entirely
manual. `waldur-matrix-init` still renders the descriptor into the
`waldur_matrix_secrets` volume with mastermind's
`generate_appservice_registration`, so it claims the same user and room-alias
namespaces the register container would.

The default config has `WALDUR_MATRIX_OPEN_REGISTRATION=false`, so signing up from a client, such as Element Web's sign-up form, needs the registration token: no client can sign up without it. The appservice token can still register accounts, as Tuwunel exempts appservice requests from the token check. Use Tuwunel's Synapse-compatible admin endpoint (HMAC-keyed by the registration secret) to provision the admin user. That endpoint is not served through Caddy, so the snippet below runs inside the Compose network, in a throwaway `waldur-matrix-init` container that has the secrets volume mounted. It does the whole thing — create the admin, find the admin room, post the `!admin appservices register` message with the descriptor and then `!admin users make-user-admin` for the bot, print Tuwunel's replies. Choose the admin's username, and type its password at the prompt, so it lands neither in shell history nor on a command line:

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

The register container, or the snippet's second command, makes the bot a homeserver admin. Waldur calls the homeserver's admin API as the bot: resetting a user's chat encryption from the drawer goes through `/_synapse/admin/v1/reset_password`, and a user deactivated in Waldur is locked on the homeserver the same way. Without admin rights the homeserver refuses those calls. Nothing makes the bot an admin by accident: Tuwunel runs with `grant_admin_to_first_user = false`, and the admin API is reachable only on the internal network.

**Treat the appservice token as a homeserver admin credential.** Waldur's registration claims every local user ID, so the appservice token (`AS_TOKEN`) can act as any account on the homeserver, `@waldur-bootstrap` and the other admins included, from the moment the appservice is registered. Once the bot is an admin, the token can also call the admin API as the bot, for example to reset any account's password and take it over. On Tuwunel, being a homeserver admin means being a member of `#admins:<your-domain>`, so `make-user-admin` joins the bot to that room. The bot itself answers commands only in Waldur's own rooms: admin-room traffic reaches its sync but triggers nothing. Anyone holding the appservice token, however, can post `!admin` commands there as the bot.

The token is stored in four places: `secrets.env` and the rendered `waldur-registration.yaml` in the `waldur_matrix_secrets` volume; Waldur's Constance settings in `waldur-db`, which Waldur staff can read through the settings API; and the homeserver's `tuwunel_data`, which holds the registration and the admin room's history, where each registration is posted as a plain message, `HS_TOKEN` included. Backups of both volumes and of the database carry it. Tuwunel 1.9.3 also writes the `HS_TOKEN` into its log, `docker logs tuwunel`, whenever a call to Waldur fails to go through, because the token travels in the URL of each call and the warning quotes it. Restrict access to the volumes, the database, the homeserver's log and their backups accordingly, and if a token may have been exposed, rotate it as described under [Token rotation](#token-rotation).

Admins are created through the shared-secret API, with `"admin": true`, as the register container and the snippet do. Tuwunel runs with `grant_admin_to_first_user = false`, so no account becomes an admin just by being the first one. Otherwise Waldur, which registers an account for whoever opens the chat first, could hand a user the homeserver's admin room. Once created, the admin can sign in to Element Web with that username and password.

`/_synapse/admin/*` is not served through Caddy, which answers it with `404`; Waldur reaches the admin API on the internal network (`MATRIX_HOMESERVER_URL`).

On that network Waldur and the homeserver call each other over plain HTTP (`http://tuwunel.internal:6167`, `http://waldur-mastermind-api:8080`), and Waldur calls LiveKit's room API the same way (`http://livekit.internal:7880`). These calls carry the appservice tokens, the passwords and tokens Waldur sets or mints for users, and LiveKit room-admin tokens. Every container on the Compose network can reach those addresses.

## The Matrix bot

The `matrix` profile also starts `waldur-matrix-bot`, Waldur's member of every
Waldur room. It runs on a Matrix device of its own and holds that device's
keys. Every Waldur room is encrypted, so it is the only process that can post
into them: every message Waldur sends as the bot waits in `waldur-db` until the
bot posts it. Clients share their room keys with its device as with any
member's, so it decrypts every message in those rooms, not only the commands
sent to it. It needs the appservice registered (above): until then it
restarts with a sign-in error. It also needs to be a homeserver admin (above)
for the drawer's encryption reset and for locking users deactivated in Waldur.

The bot also makes every history export and writes rooms' earlier keys into
new members' key backups, so that they can read what was said before they
joined. While it is down, exports stay `pending` and are made once it starts,
and disabling a room with `MATRIX_HISTORY_EXPORT_ENABLED` on cannot finish: the
room is not archived until its history is exported, so it goes to `error` at
once when the bot is not running, or after 15 minutes when the bot does not
finish the export in time. Disable it again once the bot runs.

Run exactly one. It holds a lease in `waldur-db`, and a second one refuses to
start while the lease is held. Its keys live in `waldur-db` too (schema
`matrix_bot`), pickled under a key that is encrypted with Waldur's field
encryption key, `FIELD_ENCRYPTION_KEY`, or with a key derived from
`GLOBAL_SECRET_KEY` while that is unset (the default), so a database backup
carries them and no volume is needed.
Exports do spool encrypted temporary files to the container's `/tmp`, up to a
few hundred MB each with media export on.

```bash
docker logs waldur-matrix-bot 2>&1 | grep "running on device"
```

Because its keys live in the database, a copy of that database carries the
bot's identity. Before starting a stack on a restored copy of another
deployment's database (a staging copy of production, say), leave out the
`matrix` profile or drop the copy's `matrix_bot` schema and
`matrix_chat_matrixbotidentity` rows. Otherwise a second bot runs as the same
device, can read the original's rooms, and corrupts both bots' sessions. A
copy that keeps the same `FIELD_ENCRYPTION_KEY` also yields every user's
escrowed recovery key and every history export, so treat it as you would
production.

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

With `WALDUR_MATRIX_REGISTER_APPSERVICE=false` the register container does
nothing, `--admin-token-stdin` included, so neither recipe on this page
replaces the registration. After the `up`, which renders the new tokens into
`waldur-registration.yaml`, post `!admin appservices unregister waldur` in the
admin room as a homeserver admin, then `!admin appservices register` with the
new descriptor, as in [Registering by hand](#registering-by-hand). Running that
snippet again does not do it: its first step, creating the admin, fails because
the account exists. To print the descriptor:

```bash
docker compose --profile matrix run --rm --no-deps --entrypoint cat \
  waldur-matrix-init-volume /var/lib/waldur/matrix/waldur-registration.yaml
```

### Rotating with password login off

With `WALDUR_MATRIX_LOGIN_WITH_PASSWORD=false`, as with single sign-on, the
bootstrap admin cannot sign in. An `up` with working tokens then cannot read
the homeserver's copy of the registration, so it only warns and changes
nothing, and a rotation fails after init has seeded the new tokens, with
"Password login is disabled on the homeserver". Run the register container once
more with a homeserver admin's access token on its standard input. Passed this
way, the token lands in no container's environment, where `docker inspect`
would show it, and the one-off container is removed when it exits.

To get that token, create a temporary admin and, after the run, have it
deactivate itself, with the two `waldur shell` snippets under
[Token rotation](https://docs.waldur.com/latest/developer-guide/admin-guide/matrix-appservice-setup/#token-rotation)
in Waldur's admin guide. Run them in the worker container: it reaches the
homeserver's admin API, which Caddy does not serve, and holds the registration
secret in Constance, the same value as `REG_TOKEN` in `secrets.env`, so no
secret leaves Waldur. Put `docker exec waldur-mastermind-worker` in front of the
first snippet's `waldur shell`, and `docker exec -i` in front of the second's,
which reads the token on its standard input. Between the two, register with
the token:

```bash
# The guide's first snippet: creates the admin and prints its token
TOKEN=$(docker exec waldur-mastermind-worker waldur shell -c '
<the first snippet's Python>
' | sed -n 's/^TOKEN //p')

printf '%s\n' "$TOKEN" | docker compose --profile matrix run --rm --no-deps -T \
  waldur-matrix-register /etc/waldur/matrix/register-matrix.sh --admin-token-stdin

# The guide's second snippet: the admin deactivates itself
printf '%s\n' "$TOKEN" | docker exec -i waldur-mastermind-worker waldur shell -c '
<the second snippet's Python>
'
unset TOKEN
```

The same `run` with an admin's token applies any other change the bootstrap
admin cannot read with password login off, such as a new
`WALDUR_MATRIX_APPSERVICE_URL`.

### Rotating the registration token

`REG_TOKEN` is both the homeserver's registration token and the shared secret
that creates homeserver admins, and Waldur staff can read it in Constance
(`MATRIX_USER_REGISTRATION_SECRET`). Rotate it on its own, leaving the other
lines of `secrets.env` as they are:

```bash
docker compose --profile matrix run --rm --no-deps --entrypoint sh waldur-matrix-init-volume -c '
  sed -i "s/^REG_TOKEN=.*/REG_TOKEN=$(openssl rand -hex 32)/" /var/lib/waldur/matrix/secrets.env'
docker compose --profile matrix up -d
docker wait waldur-matrix-register
docker compose restart tuwunel
```

`up` seeds the new token into Constance and renders it into `tuwunel.toml`,
but leaves Tuwunel running with the old one, since it reads its configuration
only at start; the restart applies it. Until then Waldur provisions new users
through its appservice instead of with the token. The register container
signs in with `BOOTSTRAP_PASSWORD` and does not use the token on a homeserver
that is already set up, so it is not affected.

To replace `BOOTSTRAP_PASSWORD`, change it on the homeserver first: as a
homeserver admin, post `!admin users reset-password waldur-bootstrap` in the
admin room, and Tuwunel answers with a generated password. With password login
on, that admin can be `@waldur-bootstrap` itself in a Matrix client; with it
off, only a temporary admin's token can post it, as the setup guide's second
snippet posts its command. Then write that
into the `BOOTSTRAP_PASSWORD=` line of `secrets.env` the same way. The reply
stays in the admin room's history in `tuwunel_data`, as the registrations do.

## Token lifetimes

Waldur's chat drawer signs in with a refresh token, so its access tokens expire after `access_token_ttl` (300 seconds) and are renewed in the background; a page left silent for `refresh_token_ttl` (86400 seconds, idle), e.g. on a suspended laptop, starts a new session through Waldur. Waldur also signs out its chat devices idle for more than 24 hours, when a user starts a session and in a daily job at 03:45 UTC, so whatever the refresh lifetime, an idle drawer's device lasts at most about two days while the daily job runs; it skips a run when the homeserver does not answer. Clients that sign in without a refresh token, such as Element with a password, keep non-expiring tokens. To change the lifetimes, edit `config/matrix/tuwunel.toml.template`; `access_token_ttl` must be positive, as Tuwunel reads `0` as "expire immediately".

Tuwunel reads its configuration only at startup, and `tuwunel.toml` is rendered from the template only when `waldur-matrix-init` runs, on `up`. After upgrading or editing the template, re-render it and restart Tuwunel, which an `up` leaves running with the old values:

```bash
docker compose --profile matrix up -d
docker compose restart tuwunel
```

## Capacity

Homeport keeps one `/sync` long-poll open on the homeserver for every
signed-in user who is a member of an active room, in every open tab, whether
or not the chat drawer is open: it connects in the background to show the
unread badge. Size the homeserver for those users, not only for the ones
chatting.

**One homeserver supports 1000 concurrent users with 4 CPU cores.** Measured on
a MacBook Pro (Apple M4 Pro, 12 cores, 24 GiB) under Docker Desktop
with 12 CPUs and 7.75 GiB, with this add-on (Tuwunel v1.9.3, the shipped
`tuwunel.toml.template`):

| Concurrent users | `cpus` on `tuwunel` | p95 delivery | CPU used, cores (average / peak) | Memory |
| --- | --- | --- | --- | --- |
| 500 | 2 | 0.38 s | 0.6 / 2.1 | 250 MiB |
| 1000 | 2 | 71 s, fell behind | 2.0 / 2.2 | 470 MiB |
| 1000 | 4 | 0.41 s | 1.9 / 4.1 | 320 MiB |
| 500 | none | 0.10 s | 0.4 / 1.1 | 270 MiB |
| 1000 | none | 0.14 s | 1.8 / 4.3 | 310 MiB |
| 2000 | none | 1.6 s, p99 5.7 s | 5.4 / 9.3 | 490 MiB |
| 3000 | none | 77 s | 9.5, saturated | 1.1 GiB |

Delivery runs from the start of the send request to the message arriving in
another member's `/sync`. Users and rooms were created by Waldur: rooms of 25
members plus the bot, so Waldur's appservice received the homeserver's
transactions as in production. Each user synced as the drawer does (30 s
long-polls, presence on, access tokens refreshed every 5 minutes) and sent a
message every 5 minutes on average, busier than most project chats; one in ten
posted a read receipt for every message, as a drawer open on the room does.
Each step started with every user loading the page within 30 s.

CPU grows faster than the number of users: from 1000 to 2000 users it tripled.
Idle connections are cheap (1000 users sending nothing took half a core); what
costs is fanning messages and read receipts out to the members of each room.
At 2000 users the page loads at the start saturated nine cores and p99
delivery passed 5 s; at 3000, messages took over a minute.

The figure does not cover:

- Server hardware. It was measured on a laptop, which also ran the rest of the
  Waldur stack and the load generator.
- End-to-end encryption. Messages were plain text of the size of an encrypted
  one. The drawer keeps its keys in memory, so every page load is a new device:
  it uploads its keys, the clients of the other members fetch them, and each
  sender's next message shares its session key with the new device, one
  to-device message per device in the room. A device signed out, by Waldur's
  daily prune too, makes senders share a new key with every device. Each page
  load also rehydrates the user's dehydrated device, which collects the room
  keys sent while no drawer was open and is then replaced by a fresh one, and
  restores the user's key backup in the background; both grow with the history
  the user can read. The dehydrated device is one more device per user that
  senders share keys with. None of this was simulated, so take the figure as an
  upper bound.
- Other traffic. One room per user, no typing notifications, media, calls or
  federation, and a database with little history. Caddy was not in the path.
  Calls add nothing to size for here: their media is encrypted end to end in
  the browsers and LiveKit only forwards the encrypted frames.

Before going past 1000 concurrent users, measure on your own hardware, on a
test deployment rather than production, with load shaped like the above:
users and rooms created through Waldur, so that its appservice is in the path,
each user syncing as the drawer does, and every user loading the page at the
start.

### Homeserver resources

The compose file sets no limits on `tuwunel`, so it shares the host with
Waldur. For up to 1000 concurrent users, give the host about 4 cores and 4 GiB
of memory on top of what Waldur needs. To cap the homeserver, add an override:

```yaml
# docker-compose.override.yml
services:
  tuwunel:
    cpus: 4
    # About 1 GiB plus 0.2 GiB per CPU core of the host, see below.
    mem_limit: 4g
```

- **CPU.** At 1000 users the homeserver used under 2 cores on average, but page
  loads and bursts of messages took it to 4. Leave `cpus` off or set it to at
  least 4: at 2 the same load fell behind and never caught up.
- **Memory.** Tuwunel sizes its caches from the CPU cores of the host, not from
  `cpus`: its defaults scale them with the core count, and on the 12-core
  machine above they could grow to about 2.4 GiB, with `cpus: 2` as well. They
  fill as the history grows, not with the number of users, and held under
  100 MiB here. A `mem_limit` below them gets the container killed once the
  database is large enough, so plan on roughly 1 GiB plus 0.2 GiB per core of
  the host.

### Bot resources

The bot (`waldur-matrix-bot`) decrypts every message in every Waldur room, makes
every history export, up to three at a time, and writes rooms' earlier keys into
new members' key backups. The compose file sets no limits on it. An export keeps
a few MiB of working files in memory and spills the rest, encrypted, to
temporary files in the container's `/tmp`; with `MATRIX_EXPORT_MEDIA` on, each
export holds up to 200 MB of media, in files of up to 50 MB. One attachment at a
time is held in memory, and saving an export reads its files whole, so with
media export on leave the bot a few hundred MiB of headroom, and more if you
cap it with `mem_limit`. Exports running side by side take turns at both, so
three exports need no more memory than one.

### Database growth

With `MATRIX_HISTORY_EXPORT_ENABLED` on, a task at 02:00 every night queues a
full-history export of every active room, and with `MATRIX_EXPORT_MEDIA` on each
one carries its media too, up to 200 MB. Exports are stored, encrypted, in
`waldur-db` and kept for `MATRIX_HISTORY_EXPORT_RETENTION_DAYS`, 90 by default,
along with each room's newest completed export whatever its age. Plan the disk
behind `waldur-db` and its backups for about 90 daily copies of every active
room's history and media; encrypted files do not compress.

### One replica

Tuwunel is one process with an embedded RocksDB database on the `tuwunel_data`
volume. It scales up, not out: a second instance cannot share the load.
Scaling up has diminishing returns, since each added core buys fewer users than
the last: at the traffic above, 2000 concurrent users was already the knee with
12 cores.

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
That includes `oidc` itself: when you turn single sign-on off, set the method
back to `none` or `password` there. Otherwise Waldur keeps refusing chat to
users who did not sign up through the identity provider, and keeps pointing
users at a single sign-on the homeserver no longer offers.

`waldur-matrix-init` writes the client secret to `sso_client_secret` in the
secrets volume, not into `tuwunel.toml`. It checks the settings before it
renders anything, and a refused run keeps the previous configuration. It
refuses a missing issuer, client ID, secret or registration method, a `WALDUR_MATRIX_SSO_ENABLED`
other than `true` or `false`, a name with quotes, backslashes or control
characters, a client ID or brand with anything but letters, digits, `.`, `_`
and `-`, an issuer that is not an `https://` URL, and an unrecognised claim.
It also refuses single sign-on together with
`WALDUR_MATRIX_OPEN_REGISTRATION=true`: with `trusted`, anyone could register
`@bob` first and receive bob's SSO login. Registration with the token stays
open, though: `tuwunel.toml` keeps `allow_registration = true` with the
registration token from `secrets.env`, which Waldur also holds in its settings,
where staff can read it. Whoever holds the token can register `@bob` before
Waldur provisions bob, and then receives bob's SSO login too. The Helm chart
refuses single sign-on with any registration open; Waldur provisions users
through its appservice when registration is closed. The homeserver is
configured so SSO lands in Waldur's account:

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
  Matrix localparts (lowercase letters, digits, `. _ - / +`).
- `trusted = true` signs in to the existing account that matches the claim, and
  that is *any* existing account with that name, so keep `sub` unless the IdP
  controls usernames. Without it, Tuwunel refuses the login: it signs in only
  to accounts it created through SSO, and Waldur provisioned these.
- `registration = false`: SSO creates no accounts and only signs in to
  existing ones, with `trusted` any whose name matches the claim, hence
  `forbidden_usernames`.
- `forbidden_usernames` closes accounts that are not a Waldur user's to SSO.
  The bot's localpart (`WALDUR_MATRIX_BOT_LOCALPART`) and `waldur-bootstrap`,
  reserved for the bootstrap admin that automatic registration creates,
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

## LiveKit / voice & video notes

`WALDUR_LIVEKIT_NODE_IP` advertises the host's RTC media address to clients. The default `127.0.0.1` is correct for a local demo only — for any reachable deployment, set this to the host's public IP address so remote clients can connect. It must be an address: LiveKit refuses to start with a host name (`invalid ip`). If you only have a name, resolve it and put the result in `.env`, e.g. `dig +short A waldur.example.org | tail -n 1`.

The RTC media ports, 7881/tcp and 7882/udp, must also be reachable from clients. LiveKit advertises these container ports at `WALDUR_LIVEKIT_NODE_IP` and knows nothing of Docker's port mapping, so keep `WALDUR_MATRIX_RTC_TCP_PORT` and `WALDUR_MATRIX_RTC_UDP_PORT` at their defaults: with another host port, clients still dial 7881/7882 and calls carry no media, unless something in front of the host forwards those ports to the ones you chose.

`WALDUR_LIVEKIT_KEY` / `WALDUR_LIVEKIT_SECRET` default to development values. Anyone who knows them can mint a token for any call, so **override both** for anything beyond a local demo, with a secret of at least 32 characters. With `--profile matrix-rtc` and a `WALDUR_DOMAIN` other than `localhost` or `host.docker.internal`, the one-shot `livekit-credentials-check` refuses the development values or a shorter secret, and `docker compose up -d` fails with `service "livekit-credentials-check" didn't complete successfully`. `livekit`, which waits for the check, does not start. The failed command can also leave other services unstarted: on a first start, or after `docker compose down`, the API, the workers, HomePort, Caddy and the homeserver stay down, so Waldur itself is down, not only calls, while the database migration may still have run. Services that were running and that this `up` does not change keep running. Set `WALDUR_LIVEKIT_KEY` and `WALDUR_LIVEKIT_SECRET` in `.env`, or turn calls off again (`WALDUR_MATRIX_RTC_ENABLED=false` and no `--profile matrix-rtc`), and run `up -d` again.

The LiveKit secret, and the single sign-on client secret, reach containers as environment variables: both `waldur-matrix-init`'s, the LiveKit secret also `livekit-credentials-check`'s and `livekit`'s `LIVEKIT_CONFIG`. `docker inspect` on those containers shows them.

### TURN relay (symmetric NAT / iCloud Private Relay)

Direct media to `WALDUR_LIVEKIT_NODE_IP` fails for clients behind symmetric NAT or proxies that don't carry WebRTC UDP. Enabling TURN gives LiveKit a relay those clients fall back to.

Set `WALDUR_MATRIX_TURN_ENABLED=true` (within `--profile matrix-rtc`). The stack uses **TURN/UDP on port 443** — `udp_port` is the port LiveKit advertises to clients, and 443 is the firewall-friendly choice. Because the stack is single-host, the relay lives at `WALDUR_DOMAIN:443/udp` — the same IP that already serves the web UI, so **no extra DNS record is needed**.

This mode needs **no certificate**: TURN/UDP isn't TLS, so there is nothing to provision or renew. It also doesn't collide with Caddy — Caddy binds `443/tcp` (HTTPS) while TURN takes `443/udp`, which is otherwise free on the host.

Open **`443/udp`** on any upstream firewall / cloud security group (the same way `443/tcp` is already opened for the web UI). Keep `WALDUR_MATRIX_TURN_UDP_PORT` at `443` for the same reason as the media ports: LiveKit advertises the relay on 443 whatever the host port is.

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
gets `403`, the token belongs to neither, and `waldur_matrix_diagnostics_up`
stays `0`.

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
            to a support or staff user: a 403 means it belongs to neither.
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
| `WaldurMatrixDiagnosticsDown` | The diagnostics call failed for 10 minutes | warning | `docker logs waldur-metrics-exporter`. `403` means the token belongs to neither a support nor a staff user; anything else, `docker logs waldur-mastermind-api`. |
| `WaldurMatrixHomeserverUnreachable` | `homeserver_reachable` failed for 5 minutes while a homeserver URL is set | critical | `docker logs tuwunel`. A `tuwunel` container that is up but not answering after a tag change is migrating its database: do not restart it, see [Pinned image tags](#pinned-image-tags). |
| `WaldurMatrixBotNotRunning` | `bot_running` failed for 10 minutes while a homeserver URL is set | warning | `docker logs waldur-matrix-bot`, see [The Matrix bot](#the-matrix-bot). |
| `WaldurMatrixBotSignInFailing` | `bot_whoami` failed for 10 minutes while the homeserver is reachable | warning | The appservice registration: `docker logs waldur-matrix-register`, and [Token rotation](#token-rotation) if the tokens changed. |
| `WaldurMatrixAppservicePingFailing` | `appservice_ping` failed for 10 minutes while `bot_whoami` passes | warning | That `tuwunel` can reach the API at the registered URL (`http://waldur-mastermind-api:8080` unless `WALDUR_MATRIX_APPSERVICE_URL` changes it), and `docker logs waldur-mastermind-api`. |
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

Then in `.env`: `WALDUR_MASTERMIND_IMAGE_TAG=local-arm`, `WALDUR_HOMEPORT_IMAGE_TAG=local-arm`, `DOCKER_REGISTRY_PREFIX=`. If the arm64 build fails, build with `--platform linux/amd64` instead, which runs under QEMU emulation and is slow.

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

## Backup and restore

Back up these four together, with the bot and the homeserver stopped.
[Backup and restore](https://docs.waldur.com/latest/developer-guide/admin-guide/matrix-appservice-setup/#backup-and-restore)
in Waldur's admin guide says what each holds, why they must come from the same
moment, and why a history export is not a backup.

| What | Holds |
|---|---|
| `tuwunel_data` volume | The homeserver's database, media included |
| `waldur_matrix_secrets` volume | The appservice and registration tokens, and `BOOTSTRAP_PASSWORD`, which registration signs in with |
| `waldur-db` | Rooms and Matrix profiles, the tokens in Constance, users' escrowed recovery keys, the bot's keys (schema `matrix_bot`), and the history exports, files included: Waldur's default `DatabaseStorage` keeps them in the database, encrypted, each export's key in its row |
| `.env` | `GLOBAL_SECRET_KEY` and `FIELD_ENCRYPTION_KEY`: the latter, or a key derived from `GLOBAL_SECRET_KEY` while it is unset (the default), unlocks the recovery keys, the bot's keys, every history export and the secret Constance settings, tokens included, and none of them can be read without it. During a key rotation, `FIELD_ENCRYPTION_KEY_FALLBACKS` as well. Also `WALDUR_TUWUNEL_IMAGE_TAG`, and `WALDUR_LIVEKIT_KEY` and `WALDUR_LIVEKIT_SECRET` for calls |

### Taking a backup

Tuwunel 1.9 can also back its database up while it runs (`database_backup_path`
and `!admin server backup-database`), but the add-on does not configure it, an
admin has to run the command in the admin room, and it leaves media out. A copy
of the stopped volume needs none of that and includes media. Chat is down while
it is taken; Waldur is not.

```bash
mkdir -p matrix-backup
docker compose --profile matrix stop waldur-matrix-bot tuwunel
docker exec waldur-db pg_dump -U waldur -Fc waldur > matrix-backup/waldur.dump
docker run --rm --volumes-from tuwunel alpine:3 \
  tar -C /var/lib/tuwunel -czf - . > matrix-backup/tuwunel_data.tar.gz
docker run --rm --volumes-from tuwunel alpine:3 \
  tar -C /etc/waldur/matrix -czf - . > matrix-backup/waldur_matrix_secrets.tar.gz
cp .env matrix-backup/
docker compose --profile matrix up -d
```

The bot is stopped with the homeserver so that the keys in the dump match the
homeserver's copy. `--volumes-from tuwunel` mounts the container's own volumes,
whatever the Compose project is called; `docker compose run -v tuwunel_data:…`
mounts a new, empty volume of that name instead. Move the files off the host,
and restrict access to them as to the database: together they hold every token
and the keys to everything encrypted in the dump, and, with the homeserver's
volume, the keys to every user's key backup, and so to every encrypted message.

History exports are encrypted and do not compress, so `waldur.dump` grows by
about as much as the exports take up.

LiveKit keeps no state: only `WALDUR_LIVEKIT_KEY` and `WALDUR_LIVEKIT_SECRET`
matter, and they are in `.env`. Nothing of a call needs restoring, but calls in
progress drop while the homeserver is stopped, and none can start until it is
back: Waldur checks each caller at the homeserver before it issues a call
token.

### Restoring everything

After losing the host or its disk, restore the whole set. Waldur and the
homeserver then come back at the same point, and nothing needs repairing.
Use the same `WALDUR_TUWUNEL_IMAGE_TAG` as the backup, or a newer one (see the
downgrade warning under [Pinned image tags](#pinned-image-tags)).

```bash
cp matrix-backup/.env .env
docker compose up -d --wait waldur-db
docker exec -i waldur-db pg_restore -U waldur -d waldur --no-owner < matrix-backup/waldur.dump
docker compose --profile matrix run --rm --no-deps -T --entrypoint tar waldur-matrix-init-volume \
  -C /var/lib/waldur/matrix -xzf - < matrix-backup/waldur_matrix_secrets.tar.gz
docker compose --profile matrix create tuwunel
docker run --rm -i --volumes-from tuwunel alpine:3 \
  tar -C /var/lib/tuwunel -xzf - < matrix-backup/tuwunel_data.tar.gz
docker compose --profile matrix up -d
docker wait waldur-matrix-register
docker logs waldur-matrix-register
# Expect: Appservice was already registered on the homeserver; the registration is unchanged.
```

`create` makes the homeserver's container and its empty volume without starting
it. Do not `up` the `matrix` profile before the volume is restored: Tuwunel
would create a new database in it, and the archive cannot be unpacked over that.

### Restoring only the homeserver

When only `tuwunel_data` is lost or damaged, by a failed Tuwunel upgrade for
example, restore it alone:

```bash
docker compose --profile matrix stop waldur-matrix-bot tuwunel
docker compose --profile matrix create tuwunel
# What the volume holds now, in case the backup turns out to be the wrong one
docker run --rm --volumes-from tuwunel alpine:3 \
  tar -C /var/lib/tuwunel -czf - . > tuwunel_data-replaced.tar.gz
docker run --rm -i --volumes-from tuwunel alpine:3 \
  sh -c 'find /var/lib/tuwunel -mindepth 1 -delete && tar -C /var/lib/tuwunel -xzf -' \
  < matrix-backup/tuwunel_data.tar.gz
docker exec waldur-db psql -U waldur -d waldur -c 'DELETE FROM matrix_bot.synctokens'
docker compose --profile matrix up -d
```

The registration comes back with the volume, so `waldur-matrix-register`
changes nothing, unless the tokens were rotated after the backup: then it
replaces the registration, as after a rotation (with password login off, see
[Rotating with password login off](#rotating-with-password-login-off)).

Waldur's database is now newer than the homeserver.
[Restoring only the homeserver](https://docs.waldur.com/latest/developer-guide/admin-guide/matrix-appservice-setup/#restoring-only-the-homeserver)
in Waldur's admin guide says what that breaks: the `DELETE` above resets the
bot's read position, without which it skips events; new chat sessions may not
reach the bot for a while; users and rooms created after the backup are
missing, which its repair snippet fixes; and members' key backups roll back,
which its last command refills. Run its `waldur shell -c "…"` commands with
`docker exec waldur-mastermind-worker` in front, and the repair snippet with
`docker exec -i waldur-mastermind-worker waldur shell <<'EOF'`.

### Restoring only Waldur's database

Restored alone to an older dump, `waldur-db` is older than the homeserver; see
[Restoring only Waldur's database](https://docs.waldur.com/latest/developer-guide/admin-guide/matrix-appservice-setup/#restoring-only-waldurs-database).
Where you can, restore the homeserver from the same backup set as well.

### Checking a restore

`GET /api/admin/matrix/diagnostics/` (staff) passes every check except
"Public homeserver reachable (browser path)" (see
[Troubleshooting](#troubleshooting)) and, without calls, "LiveKit (RTC)
configured"; "History exports" (`history_exports`) shows no failures. Then send `!help` in a room: the bot answers.

Where history export is on, download the newest completed export
(`GET /api/matrix/exports/?state=completed`, then
`GET /api/matrix/exports/<uuid>/download/export/`). A `409` means the export
cannot be decrypted, most likely because the restored `waldur-db` does not match
`FIELD_ENCRYPTION_KEY` in `.env` (or `GLOBAL_SECRET_KEY`, while that is unset):
then the recovery keys and the bot's keys cannot be read either.

## Troubleshooting

- **`waldur-matrix-init` fails and Tuwunel does not start**: read `docker logs waldur-matrix-init`. `init_matrix_settings` refuses appservice tokens in Constance that no deployment seeded, for example from an earlier run of the Setup wizard, and writes nothing. To hand the tokens to compose, clear `MATRIX_APPSERVICE_AS_TOKEN` and `MATRIX_APPSERVICE_HS_TOKEN` under **Administration → Configuration → Matrix chat → Settings**, and `up` again; otherwise start from a fresh stack.
- **`M_UNKNOWN_TOKEN` in worker logs after a token rotation**: the homeserver still holds the registration with the old tokens. Check `docker logs waldur-matrix-register` and see [Token rotation](#token-rotation). Registering the descriptor again by hand does not fix it on its own: Tuwunel keeps the old tokens for an id it already has, so unregister first.
- **Chat drawer says encryption is unavailable in this browser**: the browser refused the encryption WebAssembly. The homeport `Content-Security-Policy` in the `Caddyfile` must keep `'wasm-unsafe-eval'` in `script-src`; it allows compiling WebAssembly only, not `eval()` of JavaScript.
- **Calls in encrypted rooms fail after a CSP change**: calls encrypt their media in a Web Worker that homeport serves from its own origin (`/assets/e2eeWorker-*.js`), so `script-src 'self'` in the `Caddyfile` already covers it and no `worker-src` is set. A customized policy that sets `worker-src` must include `'self'`.
- **Browser chat drawer fails to connect**: the backend talks to Tuwunel internally at `http://tuwunel.internal:6167` (Docker DNS); the browser must reach Tuwunel through Caddy at `https://${WALDUR_DOMAIN}`. `waldur-matrix-init` seeds both — backend uses `MATRIX_HOMESERVER_URL`, browser-facing endpoints serve `MATRIX_HOMESERVER_PUBLIC_URL`. If the chat drawer logs CSP errors connecting to `tuwunel.internal`, verify `MATRIX_HOMESERVER_PUBLIC_URL` is set: `docker exec waldur-mastermind-worker waldur shell -c "from constance import config; print(config.MATRIX_HOMESERVER_PUBLIC_URL)"`.
- **A call shows "Could not connect to the call."**: confirm `--profile matrix-rtc` is active and `WALDUR_MATRIX_RTC_ENABLED=true`, then check the call token request to `https://${WALDUR_DOMAIN}/api/matrix/livekit/…` in the browser's network tab and `docker compose logs waldur-mastermind-api`. `403` means Waldur refused the caller (not joined to the room, or an unknown device). `503` means Waldur could not reach the homeserver or LiveKit, or the LiveKit settings are missing: check that `waldur-matrix-init` ran with RTC enabled.
- **Diagnostics shows "Public homeserver reachable" as FAIL even though the chat works**: the reachability probe at `/api/admin/matrix/diagnostics/` runs from inside the mastermind container. The public URL (`https://${WALDUR_DOMAIN}`) is a Caddy-proxied address reachable from the browser, not from the backend's network namespace — so the probe gets `Connection refused`. The "Public homeserver URL configured" check above it confirms the value is set; verify the chat round-trips end-to-end from a browser instead of trusting this single probe.
- **Communication tab missing on a project**: requires three things — the `project.show_matrix_chat` feature flag is on, a Matrix room exists for the project, AND the room cache has populated. The third only happens after the project view is visited at least once in the current session. If you navigate directly to `/projects/<uuid>/communication/` and get 404, visit `/projects/<uuid>/` first, then the tab appears in the nav.
