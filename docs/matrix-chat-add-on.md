# Matrix chat add-on

Waldur ships an optional Matrix chat integration (the `matrix_chat` Django app and the homeport `src/matrix/` views). When the add-on is enabled, project members can chat in per-project Matrix rooms; with the `matrix-rtc` sub-profile they can also start voice/video calls from the chat.

The add-on bundles a [Tuwunel](https://github.com/matrix-construct/tuwunel) homeserver (the same image used by the upstream dev stack) wired into the Caddy reverse proxy on the same domain — no extra DNS, no federation port. Tokens are auto-generated on first start and persisted in a Docker volume.

## Activation

Chat only:

```bash
docker compose --profile matrix up -d
```

Chat + voice/video calls:

```bash
docker compose --profile matrix --profile matrix-rtc up -d
```

The `matrix-rtc` profile requires `matrix` because `lk-jwt-service` shares Tuwunel's network namespace. Activating it on its own will fail.

## Pinned image tags

Matrix component versions live in `.env`. Bump them deliberately:

| Variable | Default | Component |
|---|---|---|
| `WALDUR_TUWUNEL_IMAGE_TAG` | `v1.9.0` | Tuwunel homeserver — requires 1.7.0+ for Synapse-compatible `registration_shared_secret`. **Kept in lockstep with the Helm chart's `matrixChat.homeserver.imageTag`** — one supported homeserver version across both packaging paths |
| `WALDUR_LIVEKIT_IMAGE_TAG` | `v1.13.7` | LiveKit SFU |
| `WALDUR_LK_JWT_IMAGE_TAG` | `0.7.0` | lk-jwt-service, 0.4.0 or newer: homeport requests call tokens from its `/get_token` endpoint. Requires explicit `LIVEKIT_FULL_ACCESS_HOMESERVERS` (auto-set) |

All three publish multi-arch (`linux/amd64` and `linux/arm64`) manifests for the pinned tags. Re-check with `docker buildx imagetools inspect <image>:<tag>` after bumps.

**Back up before bumping Tuwunel.** It migrates its embedded database in place
on the first boot of a new version, before it listens and without logging
anything, so read the
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

Tuwunel does not load appservice descriptors from a file — it requires registration via the `!admin appservices register` admin-room command. This is handled for you: the one-shot `waldur-matrix-register` container runs after the homeserver comes up, registers a bootstrap admin user, `@waldur-bootstrap`, with the generated registration token and `BOOTSTRAP_PASSWORD` from the secrets volume, and drives that admin-room command with the descriptor. There is nothing to paste.

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

Re-running `up -d` is safe. The command first checks whether the appservice token already works and exits early when it does, so an already-configured stack is a no-op rather than a failed container.

A stack registered by hand before this container existed works with it switched
on: it finds the registration in place and changes nothing. What it cannot do
there on its own is apply rotated tokens. The bootstrap account earns its admin
rights by being the homeserver's first account, and on that stack the first
account is someone else's, so rotation there takes an admin's access token (see
Token rotation). Set `WALDUR_MATRIX_REGISTER_APPSERVICE=false` to keep
registration entirely manual, as below.

### Registering by hand

The default config has `WALDUR_MATRIX_OPEN_REGISTRATION=false`, so client-side registration (Element Web sign-up form) is disabled. Use Tuwunel's Synapse-compatible admin endpoint (HMAC-keyed by the registration secret) to provision the admin user. The snippet below does the whole thing — create admin, log in, find the auto-joined admin room, post the `!admin appservices register` message with the descriptor:

```bash
# Read the registration secret from the secrets volume
REG_SECRET=$(docker compose --profile matrix run --rm --no-deps -T --entrypoint sed \
  waldur-matrix-init-volume -n 's/^REG_TOKEN=//p' /var/lib/waldur/matrix/secrets.env)

# Register an admin user via Synapse-compatible HMAC
NONCE=$(curl -ks https://localhost/_synapse/admin/v1/register | python3 -c 'import sys,json; print(json.load(sys.stdin)["nonce"])')
MAC=$(printf '%s\0alice\0alicepass\0admin' "$NONCE" | openssl dgst -sha1 -hmac "$REG_SECRET" -hex | awk '{print $NF}')
TOKEN=$(curl -ks -X POST https://localhost/_synapse/admin/v1/register \
  -H 'Content-Type: application/json' \
  -d "{\"nonce\":\"$NONCE\",\"username\":\"alice\",\"password\":\"alicepass\",\"admin\":true,\"mac\":\"$MAC\"}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

# Locate the admin room Tuwunel auto-joins the admin user to
ROOM=$(curl -ks -H "Authorization: Bearer $TOKEN" https://localhost/_matrix/client/v3/joined_rooms \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["joined_rooms"][0])')
ROOM_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$ROOM', safe=''))")

# Post the !admin appservices register command with the rendered descriptor
YAML=$(docker compose --profile matrix run --rm --no-deps -T --entrypoint cat \
  waldur-matrix-init-volume /var/lib/waldur/matrix/waldur-registration.yaml)
BODY=$(python3 -c "import json; yaml='''$YAML'''; print(json.dumps({'msgtype':'m.text','body':'!admin appservices register\n\`\`\`yaml\n'+yaml+'\n\`\`\`'}))")
curl -ks -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data-binary "$BODY" \
  "https://localhost/_matrix/client/v3/rooms/$ROOM_ENC/send/m.room.message/$(date +%s%N)"

# Confirm Tuwunel acknowledged
curl -ks -H "Authorization: Bearer $TOKEN" \
  "https://localhost/_matrix/client/v3/rooms/$ROOM_ENC/messages?dir=b&limit=2" \
  | python3 -c "import sys,json; print([c.get('content',{}).get('body','')[:80] for c in json.load(sys.stdin).get('chunk',[])])"
# Expect: ['Appservice registered with ID: waldur', '...']
```

The bot then becomes `@waldur-bot:<your-domain>` and can post on Waldur's behalf.

The snippet only registers. If the homeserver already holds a `waldur`
registration, after a token rotation say, Tuwunel answers `Duplicate id` and
keeps the old tokens. Unregister it first from the same shell, check the reply
with the confirm step, then post the register command again:

```bash
curl -ks -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data-binary '{"msgtype":"m.text","body":"!admin appservices unregister waldur"}' \
  "https://localhost/_matrix/client/v3/rooms/$ROOM_ENC/send/m.room.message/unregister-$(date +%s)"
```

**Prefer Element Web?** Set `WALDUR_MATRIX_OPEN_REGISTRATION=true` in `.env` before the first `--profile matrix up -d`, then register the admin user via the Element Web sign-up form using `REG_TOKEN` from the secrets volume. Switch the flag back to `false` afterwards (re-render takes effect on the next `--profile matrix up -d`).

## Enabling the homeport UI

Backend access to Matrix is gated by the `MATRIX_ENABLED` Constance flag. `waldur-matrix-init` switches it on only while no value is stored, so turning chat off in Administration survives the next `up`. The homeport UI is gated separately by a feature flag — enable it once via the `load_features` management command:

```bash
docker exec waldur-mastermind-worker bash -c \
  'echo "{\"project.show_matrix_chat\": true}" > /tmp/features.json && waldur load_features /tmp/features.json'
```

After a hard reload (Cmd-Shift-R / Ctrl-Shift-R), project views show the **Communication** tab — but only after a Matrix room has been created for that project (the tab is gated by `hasActiveProjectMatrixRoomInCache`). Until then, the room-creation entry point lives at `Manage → Chat` (`?tab=chat` query parameter — direct paths like `/manage/chat/` return 404).

## Token rotation

To rotate the AS/HS tokens (e.g., after credential exposure), replace both in the
secrets volume and bring the profile up again. Always both: only the AS token can
be checked, so a new HS token alone reports "already registered" while Tuwunel's
calls to Waldur start failing.

```bash
docker compose --profile matrix run --rm --no-deps --entrypoint sh waldur-matrix-init-volume -c '
  sed -i -e "s/^AS_TOKEN=.*/AS_TOKEN=$(openssl rand -hex 32)/" \
         -e "s/^HS_TOKEN=.*/HS_TOKEN=$(openssl rand -hex 32)/" \
         /var/lib/waldur/matrix/secrets.env'
docker compose --profile matrix up -d
docker wait waldur-matrix-register
docker logs waldur-matrix-register
# Expect: Appservice 'waldur' was registered under other tokens; replaced it with Waldur's.
```

`waldur-matrix-init` seeds the new tokens into Constance, and
`waldur-matrix-register` logs in as `@waldur-bootstrap`, unregisters the old
registration and registers the new one. Tuwunel does not replace a registration
that is registered again under the same id, which is why the old one is removed
first. The container fails if the homeserver still rejects the new token.

Chat is down from the moment init seeds the new tokens until the register
container finishes, usually tens of seconds. Events sent in that window, such as
a bot command, are not delivered to Waldur. The room database in `tuwunel_data`
is untouched, so existing rooms survive.

Do not delete the secrets volume to rotate: that also replaces `BOOTSTRAP_PASSWORD`,
which then no longer matches `@waldur-bootstrap` on the homeserver, and
registration fails.

### Stacks registered by hand

A stack set up before the bootstrap password existed, typically one registered
by hand, gets a `BOOTSTRAP_PASSWORD` added on its next `up`
(`waldur-matrix-init` logs it). Its homeserver admin is still not
`@waldur-bootstrap`, though, so the register container cannot log in with it.
Rotate as above, but hand over the access token of an existing homeserver admin
for the `up` that applies the new tokens:

```bash
WALDUR_MATRIX_ADMIN_TOKEN=<admin access token> docker compose --profile matrix up -d
docker wait waldur-matrix-register
docker logs waldur-matrix-register
```

`register_matrix_appservice` uses that admin to unregister the old registration
and register the new one. The token comes from your shell for that one command;
do not keep it in `.env`. Without it, the container fails instead: it creates a
`@waldur-bootstrap` that is not an admin and cannot reach the admin room.

Registering the descriptor again by hand does not rotate on its own: unregister
first, as described under Registering by hand.

## LiveKit / voice & video notes

`WALDUR_LIVEKIT_NODE_IP` advertises the host's RTC media address to clients. The default `127.0.0.1` is correct for a local demo only — for any reachable deployment, set this to the host's external IP or DNS name so remote clients can connect. The RTC media ports (`WALDUR_MATRIX_RTC_TCP_PORT`/`UDP_PORT`, default 7881/7882) must also be reachable from clients.

`WALDUR_LIVEKIT_KEY` / `WALDUR_LIVEKIT_SECRET` default to development values. **Override both** for anything beyond a localhost demo. Use a secret of at least 32 characters; LiveKit logs an error at startup for anything shorter.

**Calls need a `WALDUR_DOMAIN` that resolves to the host from inside containers.** `lk-jwt-service` shares Tuwunel's network namespace and verifies each caller's Matrix OpenID token with a federation lookup of the homeserver named `WALDUR_DOMAIN`. With `WALDUR_DOMAIN=localhost` that lookup dials `localhost:443` and `localhost:8448` inside the namespace, where nothing listens, so every call token request fails and calls never start. Chat is unaffected. Use a DNS name that points at the host, or `host.docker.internal` for a local demo on Docker Desktop. Choose it before the first start, because `WALDUR_DOMAIN` is frozen once the homeserver has data (see Pinned image tags above).

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

- **`M_UNKNOWN_TOKEN` in worker logs after a token rotation**: the homeserver still holds the registration with the old tokens. Check `docker logs waldur-matrix-register` and see Token rotation. Registering the descriptor again by hand does not fix it on its own: Tuwunel keeps the old tokens for an id it already has, so unregister first.
- **Webhook `DisallowedHost` errors**: the appservice descriptor is rendered with `url: http://waldur-mastermind-api:8080` (the Compose service name), which is in `ALLOWED_HOSTS` for the dockerised settings. If you change the URL — for example to call back via an external hostname — patch `ALLOWED_HOSTS` in `config/waldur-mastermind/override.conf.py`.
- **Browser chat drawer fails to connect**: the backend talks to Tuwunel internally at `http://tuwunel.internal:6167` (Docker DNS); the browser must reach Tuwunel through Caddy at `https://${WALDUR_DOMAIN}`. `waldur-matrix-init` seeds both — backend uses `MATRIX_HOMESERVER_URL`, browser-facing endpoints serve `MATRIX_HOMESERVER_PUBLIC_URL` (requires `waldur-mastermind` >= 8.x with the dual-URL split). If the chat drawer logs CSP errors connecting to `tuwunel.internal`, verify `MATRIX_HOMESERVER_PUBLIC_URL` is set: `docker exec waldur-mastermind-worker waldur shell -c "from constance import config; print(config.MATRIX_HOMESERVER_PUBLIC_URL)"`.
- **A call shows "Could not connect to the call."**: confirm `--profile matrix-rtc` is active, then check the call token request to `https://${WALDUR_DOMAIN}/lk-jwt/…` in the browser's network tab and `docker compose logs lk-jwt-service`. Common causes: `WALDUR_DOMAIN=localhost` (see the LiveKit notes above); a `WALDUR_DOMAIN` mismatch with `LIVEKIT_FULL_ACCESS_HOMESERVERS`; or `400 Missing room parameter` from `/lk-jwt/sfu/get`, which means the homeport image still posts to lk-jwt's legacy endpoint while lk-jwt is 0.6.0 or newer. Keep `WALDUR_HOMEPORT_IMAGE_TAG` and `WALDUR_LK_JWT_IMAGE_TAG` at the versions `.env.example` pins.
- **Diagnostics shows "Public homeserver reachable" as FAIL even though the chat works**: the reachability probe at `/api/admin/matrix/diagnostics/` runs from inside the mastermind container. The public URL (`https://${WALDUR_DOMAIN}`) is a Caddy-proxied address reachable from the browser, not from the backend's network namespace — so the probe gets `Connection refused`. The "Public homeserver URL configured" check above it confirms the value is set; verify the chat round-trips end-to-end from a browser instead of trusting this single probe.
- **Communication tab missing on a project**: requires three things — the `project.show_matrix_chat` feature flag is on, a Matrix room exists for the project, AND the room cache has populated. The third only happens after the project view is visited at least once in the current session. If you navigate directly to `/projects/<uuid>/communication/` and get 404, visit `/projects/<uuid>/` first, then the tab appears in the nav.
