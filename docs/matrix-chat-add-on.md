# Matrix chat add-on

Waldur ships an optional Matrix chat integration (the `matrix_chat` Django app and the homeport `src/matrix/` views). When the add-on is enabled, project members can chat in per-project Matrix rooms; with the `matrix-rtc` sub-profile they can also start Element Call voice/video calls.

The add-on bundles a [Tuwunel](https://github.com/matrix-construct/tuwunel) homeserver (the same image used by the upstream dev stack) wired into the Caddy reverse proxy on the same domain — no extra DNS, no federation port. Tokens are auto-generated on first start and persisted in a Docker volume.

## Activation

Chat only:

```bash
docker compose --profile matrix up -d
```

Chat + Element Call (voice/video):

```bash
docker compose --profile matrix --profile matrix-rtc up -d
```

The `matrix-rtc` profile requires `matrix` because `lk-jwt-service` shares Tuwunel's network namespace. Activating it on its own will fail.

## Pinned image tags

Matrix component versions live in `.env`. Bump them deliberately:

| Variable | Default | Component |
|---|---|---|
| `WALDUR_TUWUNEL_IMAGE_TAG` | `v1.7.1` | Tuwunel homeserver — requires 1.7.0+ for Synapse-compatible `registration_shared_secret` |
| `WALDUR_LIVEKIT_IMAGE_TAG` | `v1.12.0` | LiveKit SFU |
| `WALDUR_LK_JWT_IMAGE_TAG` | `0.5.0` | lk-jwt-service — requires explicit `LIVEKIT_FULL_ACCESS_HOMESERVERS` (auto-set) |

All three publish multi-arch (`linux/amd64` and `linux/arm64`) manifests for the pinned tags. Re-check with `docker buildx imagetools inspect <image>:<tag>` after bumps.

## One-time appservice registration

Tuwunel does not load appservice descriptors from a file — it requires registration via the `!admin appservices register` admin-room command. The `waldur-matrix-init` container renders a ready-to-paste descriptor into the `waldur_matrix_secrets` volume; do the following once after the first `--profile matrix up -d`.

The default config has `WALDUR_MATRIX_OPEN_REGISTRATION=false`, so client-side registration (Element Web sign-up form) is disabled. Use Tuwunel's Synapse-compatible admin endpoint (HMAC-keyed by the registration secret) to provision the admin user. The snippet below does the whole thing — create admin, log in, find the auto-joined admin room, post the `!admin appservices register` message with the descriptor:

```bash
# Pull the registration secret out of the shared volume
REG_SECRET=$(docker run --rm -v waldur-docker-compose_waldur_matrix_secrets:/m alpine \
  sh -c 'grep REG_TOKEN /m/secrets.env | cut -d= -f2')

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
YAML=$(docker run --rm -v waldur-docker-compose_waldur_matrix_secrets:/m alpine cat /m/waldur-registration.yaml)
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

**Prefer Element Web?** Set `WALDUR_MATRIX_OPEN_REGISTRATION=true` in `.env` before the first `--profile matrix up -d`, then register the admin user via the Element Web sign-up form using `REG_TOKEN` from the secrets volume. Switch the flag back to `false` afterwards (re-render takes effect on the next `--profile matrix up -d`).

## Enabling the homeport UI

Backend access to Matrix is gated by the `MATRIX_ENABLED` Constance flag (auto-set by `waldur-matrix-init`). The homeport UI is gated separately by a feature flag — enable it once via the `load_features` management command:

```bash
docker exec waldur-mastermind-worker bash -c \
  'echo "{\"project.show_matrix_chat\": true}" > /tmp/features.json && waldur load_features /tmp/features.json'
```

After a hard reload (Cmd-Shift-R / Ctrl-Shift-R), project views show the **Communication** tab — but only after a Matrix room has been created for that project (the tab is gated by `hasActiveProjectMatrixRoomInCache`). Until then, the room-creation entry point lives at `Manage → Chat` (`?tab=chat` query parameter — direct paths like `/manage/chat/` return 404).

## Token rotation

To rotate AS/HS tokens (e.g., after credential exposure):

```bash
docker compose --profile matrix --profile matrix-rtc down
docker volume rm waldur-docker-compose_waldur_matrix_secrets
docker compose --profile matrix --profile matrix-rtc up -d
```

On re-up, `waldur-matrix-init` generates fresh tokens, re-renders the descriptor, and re-seeds Constance. **Re-run the one-time appservice registration step** above — Tuwunel still holds the old descriptor until you re-register, and the bot will fail with `M_UNKNOWN_TOKEN` in the meantime. The room database in `tuwunel_data` is untouched, so existing rooms survive.

## LiveKit / voice & video notes

`WALDUR_LIVEKIT_NODE_IP` advertises the host's RTC media address to clients. The default `127.0.0.1` is correct for a local demo only — for any reachable deployment, set this to the host's external IP or DNS name so remote clients can connect. The RTC media ports (`WALDUR_MATRIX_RTC_TCP_PORT`/`UDP_PORT`, default 7881/7882) must also be reachable from clients.

`WALDUR_LIVEKIT_KEY` / `WALDUR_LIVEKIT_SECRET` default to development values. **Override both** for anything beyond a localhost demo.

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

After completing the **one-time appservice registration** above, visit `https://${WALDUR_DOMAIN}/projects/<uuid>/manage/?tab=chat` as a staff user and click **Create chat room**. The Manage tabs use query-param URLs (`?tab=chat`), not path segments — direct paths like `/manage/chat/` 404.

Before the registration is pasted, room creation fails with `M_UNKNOWN_TOKEN` in `docker compose logs waldur-mastermind-worker` — that is expected and is the signal that Tuwunel still needs the appservice descriptor.

## Troubleshooting

- **`M_UNKNOWN_TOKEN` in worker logs after a token rotation**: re-run the one-time appservice registration step. The descriptor Tuwunel has is stale.
- **Webhook `DisallowedHost` errors**: the appservice descriptor is rendered with `url: http://waldur-mastermind-api:8080` (the Compose service name), which is in `ALLOWED_HOSTS` for the dockerised settings. If you change the URL — for example to call back via an external hostname — patch `ALLOWED_HOSTS` in `config/waldur-mastermind/override.conf.py`.
- **Browser chat drawer fails to connect**: the backend talks to Tuwunel internally at `http://tuwunel.internal:6167` (Docker DNS); the browser must reach Tuwunel through Caddy at `https://${WALDUR_DOMAIN}`. `waldur-matrix-init` seeds both — backend uses `MATRIX_HOMESERVER_URL`, browser-facing endpoints serve `MATRIX_HOMESERVER_PUBLIC_URL` (requires `waldur-mastermind` >= 8.x with the dual-URL split). If the chat drawer logs CSP errors connecting to `tuwunel.internal`, verify `MATRIX_HOMESERVER_PUBLIC_URL` is set: `docker exec waldur-mastermind-worker waldur shell -c "from constance import config; print(config.MATRIX_HOMESERVER_PUBLIC_URL)"`.
- **Element Call fails to fetch a JWT**: confirm `--profile matrix-rtc` is active, then check `docker compose logs lk-jwt-service` — the most common cause is a `WALDUR_DOMAIN` mismatch with `LIVEKIT_FULL_ACCESS_HOMESERVERS`.
- **Diagnostics shows "Public homeserver reachable" as FAIL even though the chat works**: the reachability probe at `/api/admin/matrix/diagnostics/` runs from inside the mastermind container. The public URL (`https://${WALDUR_DOMAIN}`) is a Caddy-proxied address reachable from the browser, not from the backend's network namespace — so the probe gets `Connection refused`. The "Public homeserver URL configured" check above it confirms the value is set; verify the chat round-trips end-to-end from a browser instead of trusting this single probe.
- **Communication tab missing on a project**: requires three things — the `project.show_matrix_chat` feature flag is on, a Matrix room exists for the project, AND the room cache has populated. The third only happens after the project view is visited at least once in the current session. If you navigate directly to `/projects/<uuid>/communication/` and get 404, visit `/projects/<uuid>/` first, then the tab appears in the nav.
