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
| `WALDUR_TUWUNEL_IMAGE_TAG` | `v1.9.3` | Tuwunel homeserver — requires 1.7.0+ for Synapse-compatible `registration_shared_secret`. **Kept in lockstep with the Helm chart's `matrixChat.homeserver.imageTag`** — one supported homeserver version across both packaging paths |
| `WALDUR_LIVEKIT_IMAGE_TAG` | `v1.13.7` | LiveKit SFU |
| `WALDUR_LK_JWT_IMAGE_TAG` | `0.7.0` | lk-jwt-service, 0.4.0 or newer: homeport requests call tokens from its `/get_token` endpoint. Requires explicit `LIVEKIT_FULL_ACCESS_HOMESERVERS` (auto-set) |

All three publish multi-arch (`linux/amd64` and `linux/arm64`) manifests for the pinned tags. Re-check with `docker buildx imagetools inspect <image>:<tag>` after bumps.

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

## One-time appservice registration

Tuwunel does not load appservice descriptors from a file — it requires registration via the `!admin appservices register` admin-room command. The `waldur-matrix-init` container renders a ready-to-paste descriptor into the `waldur_matrix_secrets` volume; do the following once after the first `--profile matrix up -d`.

The default config has `WALDUR_MATRIX_OPEN_REGISTRATION=false`, so client-side registration (Element Web sign-up form) is disabled. Use Tuwunel's Synapse-compatible admin endpoint (HMAC-keyed by the registration secret) to provision the admin user. That endpoint is not served through Caddy, so the snippet below runs inside the Compose network, in a throwaway `waldur-matrix-init` container that has the secrets volume mounted. It does the whole thing — create the admin, find the admin room, post the `!admin appservices register` message with the descriptor, print Tuwunel's reply. Choose the admin's username and password first; the script refuses to run while the password is still `change-me`:

```bash
docker compose run --rm --no-deps -T --entrypoint python3 waldur-matrix-init - <<'EOF'
import hashlib, hmac, json, time, urllib.parse, urllib.request

USERNAME, PASSWORD = "matrix-admin", "change-me"
HOMESERVER = "http://tuwunel.internal:6167"
SHARED = "/var/lib/waldur/matrix"  # the waldur_matrix_secrets volume

if PASSWORD == "change-me":
    raise SystemExit("Set PASSWORD at the top of this script before running it")


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

# The admin joins the admin room, #admins:<server name>
alias = urllib.parse.quote("#admins:" + user_id.split(":", 1)[1])
room = urllib.parse.quote(call("GET", f"/_matrix/client/v3/directory/room/{alias}")["room_id"])

# Post the !admin appservices register command with the rendered descriptor
descriptor = open(f"{SHARED}/waldur-registration.yaml").read()
sent = call("PUT", f"/_matrix/client/v3/rooms/{room}/send/m.room.message/setup-{time.time_ns()}", {
    "msgtype": "m.text", "body": f"!admin appservices register\n```yaml\n{descriptor}\n```",
}, token)


def reply():
    messages = call("GET", f"/_matrix/client/v3/rooms/{room}/messages?dir=b&limit=10", token=token)
    for event in messages["chunk"]:
        if event["event_id"] == sent["event_id"]:
            return None
        if event["type"] == "m.room.message" and event["sender"] != user_id:
            return event["content"]["body"]


# Tuwunel answers asynchronously
for _ in range(10):
    time.sleep(1)
    if text := reply():
        print(text)
        break
else:
    print("No reply yet; read the admin room in a Matrix client")
EOF
# Expect: Appservice registered with ID: waldur
```

The bot then becomes `@waldur-bot:<your-domain>` and can post on Waldur's behalf.

The admin must be created this way, with `"admin": true`. Tuwunel runs with `grant_admin_to_first_user = false`, so no account becomes an admin just by being the first one. Otherwise Waldur, which registers an account for whoever opens the chat first, could hand a user the homeserver's admin room. Once created, the admin can sign in to Element Web with that username and password.

On an existing deployment, `grant_admin_to_first_user = false` demotes nobody: whoever became admin as the first account stays one. Tuwunel treats every member of the admin room (`#admins:<WALDUR_DOMAIN>`) as an admin, so check its members in a Matrix client as the admin.

`/_synapse/admin/*` is not served through Caddy, which answers it with `404`; Waldur reaches the admin API on the internal network (`MATRIX_HOMESERVER_URL`).

## The Matrix bot

The `matrix` profile also starts `waldur-matrix-bot`, Waldur's member of every
Waldur room. It runs on a Matrix device of its own and holds that device's
keys, so it is the only process that can post into an encrypted room or read
the commands sent to it there. While it runs, every message Waldur sends as the
bot goes through it. It needs the appservice registered (above): until then it
restarts with a sign-in error.

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

To rotate AS/HS tokens (e.g., after credential exposure):

```bash
docker compose --profile matrix --profile matrix-rtc down
docker volume rm waldur-docker-compose_waldur_matrix_secrets
docker compose --profile matrix --profile matrix-rtc up -d
```

On re-up, `waldur-matrix-init` generates fresh tokens, re-renders the descriptor, and re-seeds Constance. **Re-run the one-time appservice registration step** above — Tuwunel still holds the old descriptor until you re-register, and the bot will fail with `M_UNKNOWN_TOKEN` in the meantime. The room database in `tuwunel_data` is untouched, so existing rooms survive.

## Token lifetimes

Waldur's chat drawer signs in with a refresh token, so its access tokens expire after `access_token_ttl` (300 seconds) and are renewed in the background; a page left silent for `refresh_token_ttl` (86400 seconds, idle), e.g. on a suspended laptop, starts a new session through Waldur. Clients that sign in without a refresh token, such as Element with a password, keep non-expiring tokens. To change the lifetimes, edit `config/matrix/tuwunel.toml.template`; `access_token_ttl` must be positive, as Tuwunel reads `0` as "expire immediately".

Tuwunel reads its configuration only at startup, and `tuwunel.toml` is rendered from the template only when `waldur-matrix-init` runs, on `up`. After upgrading or editing the template, re-render it and restart Tuwunel, which an `up` leaves running with the old values:

```bash
docker compose --profile matrix up -d
docker compose restart tuwunel
```

## LiveKit / voice & video notes

`WALDUR_LIVEKIT_NODE_IP` advertises the host's RTC media address to clients. The default `127.0.0.1` is correct for a local demo only — for any reachable deployment, set this to the host's external IP or DNS name so remote clients can connect. The RTC media ports (`WALDUR_MATRIX_RTC_TCP_PORT`/`UDP_PORT`, default 7881/7882) must also be reachable from clients.

`WALDUR_LIVEKIT_KEY` / `WALDUR_LIVEKIT_SECRET` default to development values. Anyone who knows them can mint a token for any call, so **override both** for anything beyond a local demo, with a secret of at least 32 characters. With `--profile matrix-rtc` and a `WALDUR_DOMAIN` other than `localhost` or `host.docker.internal`, the one-shot `livekit-credentials-check` refuses the development values or a shorter secret, and `docker compose up -d` fails with `service "livekit-credentials-check" didn't complete successfully`. `livekit` and `lk-jwt-service`, which wait for the check, do not start. The failed command can also leave other services unstarted: on a first start, or after `docker compose down`, the API, the workers, HomePort, Caddy and the homeserver stay down, so Waldur itself is down, not only calls, while the database migration may still have run. Services that were running and that this `up` does not change keep running. Set `WALDUR_LIVEKIT_KEY` and `WALDUR_LIVEKIT_SECRET` in `.env`, or turn calls off again (`WALDUR_MATRIX_RTC_ENABLED=false` and no `--profile matrix-rtc`), and run `up -d` again.

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

After completing the **one-time appservice registration** above, visit `https://${WALDUR_DOMAIN}/projects/<uuid>/manage/?tab=chat` as a staff user and click **Create chat room**. The Manage tabs use query-param URLs (`?tab=chat`), not path segments — direct paths like `/manage/chat/` 404.

Before the registration is pasted, room creation fails with `M_UNKNOWN_TOKEN` in `docker compose logs waldur-mastermind-worker` — that is expected and is the signal that Tuwunel still needs the appservice descriptor.

## Troubleshooting

- **`M_UNKNOWN_TOKEN` in worker logs after a token rotation**: re-run the one-time appservice registration step. The descriptor Tuwunel has is stale.
- **Webhook `DisallowedHost` errors**: the appservice descriptor is rendered with `url: http://waldur-mastermind-api:8080` (the Compose service name), which is in `ALLOWED_HOSTS` for the dockerised settings. If you change the URL — for example to call back via an external hostname — patch `ALLOWED_HOSTS` in `config/waldur-mastermind/override.conf.py`.
- **Chat drawer says encryption is unavailable in this browser**: the browser refused the encryption WebAssembly. The homeport `Content-Security-Policy` in the `Caddyfile` must keep `'wasm-unsafe-eval'` in `script-src`; it allows compiling WebAssembly only, not `eval()` of JavaScript. A Caddyfile customized before this was added needs it added by hand.
- **Browser chat drawer fails to connect**: the backend talks to Tuwunel internally at `http://tuwunel.internal:6167` (Docker DNS); the browser must reach Tuwunel through Caddy at `https://${WALDUR_DOMAIN}`. `waldur-matrix-init` seeds both — backend uses `MATRIX_HOMESERVER_URL`, browser-facing endpoints serve `MATRIX_HOMESERVER_PUBLIC_URL` (requires `waldur-mastermind` >= 8.x with the dual-URL split). If the chat drawer logs CSP errors connecting to `tuwunel.internal`, verify `MATRIX_HOMESERVER_PUBLIC_URL` is set: `docker exec waldur-mastermind-worker waldur shell -c "from constance import config; print(config.MATRIX_HOMESERVER_PUBLIC_URL)"`.
- **A call shows "Could not connect to the call."**: confirm `--profile matrix-rtc` is active, then check the call token request to `https://${WALDUR_DOMAIN}/lk-jwt/…` in the browser's network tab and `docker compose logs lk-jwt-service`. Common causes: `WALDUR_DOMAIN=localhost` (see the LiveKit notes above); a `WALDUR_DOMAIN` mismatch with `LIVEKIT_FULL_ACCESS_HOMESERVERS`; or `400 Missing room parameter` from `/lk-jwt/sfu/get`, which means the homeport image still posts to lk-jwt's legacy endpoint while lk-jwt is 0.6.0 or newer. Keep `WALDUR_HOMEPORT_IMAGE_TAG` and `WALDUR_LK_JWT_IMAGE_TAG` at the versions `.env.example` pins.
- **Diagnostics shows "Public homeserver reachable" as FAIL even though the chat works**: the reachability probe at `/api/admin/matrix/diagnostics/` runs from inside the mastermind container. The public URL (`https://${WALDUR_DOMAIN}`) is a Caddy-proxied address reachable from the browser, not from the backend's network namespace — so the probe gets `Connection refused`. The "Public homeserver URL configured" check above it confirms the value is set; verify the chat round-trips end-to-end from a browser instead of trusting this single probe.
- **Communication tab missing on a project**: requires three things — the `project.show_matrix_chat` feature flag is on, a Matrix room exists for the project, AND the room cache has populated. The third only happens after the project view is visited at least once in the current session. If you navigate directly to `/projects/<uuid>/communication/` and get 404, visit `/projects/<uuid>/` first, then the tab appears in the nav.
