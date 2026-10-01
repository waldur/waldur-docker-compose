#!/usr/bin/env bash
# Registers the Waldur appservice with Tuwunel, closing the last manual step
# of the Matrix add-on.
#
# Runs after `init-matrix.sh` (which generates the tokens and seeds Constance)
# and after Tuwunel itself, because registration is a *runtime* call: Tuwunel
# takes appservices through the `!admin appservices register` admin-room
# command rather than from its config file. `waldur register_matrix_appservice`
# drives that conversation, reading every token it needs from the Constance
# rows init-matrix.sh just wrote.
#
# Safe to re-run: the command first checks whether the appservice token already
# works and exits early if it does, so a plain `docker compose up -d` on an
# already-configured stack is a no-op rather than a failed container.

set -euo pipefail

if [[ "${WALDUR_MATRIX_REGISTER_APPSERVICE:-true}" != "true" ]]; then
	echo "matrix-register: disabled (WALDUR_MATRIX_REGISTER_APPSERVICE=false) — register by hand, see docs/matrix-chat-add-on.md"
	exit 0
fi

HOMESERVER="http://tuwunel.internal:6167"
# The URL the *homeserver* calls back on to deliver appservice transactions —
# internal Docker DNS, not the public Caddy address.
CALLBACK_URL="${WALDUR_MATRIX_APPSERVICE_URL:-http://waldur-mastermind-api:8080}"

# Tuwunel is distroless, so compose cannot health-check it and `depends_on`
# only tells us the container started. Wait for the client API to answer
# before assuming the homeserver is ready to take an admin command.
#
# The wait has to outlast a database migration: Tuwunel migrates its embedded
# database in place before it opens the listener, prints nothing while doing
# so, and the time scales with the size of the tuwunel_data volume. This
# container is `restart: "no"`, so giving up too early fails the registration
# for the whole `up`. The cap is only a backstop against a homeserver that will
# never come up; raise it rather than lowering it.
WAIT_LIMIT="${WALDUR_MATRIX_REGISTER_WAIT_SECONDS:-3600}"
INTERVAL=2
waited=0
echo "matrix-register: waiting up to ${WAIT_LIMIT}s for ${HOMESERVER} to accept requests"
until python3 -c "
import sys, urllib.request
try:
    urllib.request.urlopen('${HOMESERVER}/_matrix/client/versions', timeout=5)
except Exception:
    sys.exit(1)
" 2>/dev/null; do
	if (( waited >= WAIT_LIMIT )); then
		echo "matrix-register: homeserver did not become reachable within ${WAIT_LIMIT}s (WALDUR_MATRIX_REGISTER_WAIT_SECONDS)" >&2
		exit 1
	fi
	if (( waited > 0 && waited % 30 == 0 )); then
		echo "matrix-register: still waiting (${waited}s) — a silent homeserver is migrating its database, not hung"
	fi
	sleep "${INTERVAL}"
	waited=$((waited + INTERVAL))
done
echo "matrix-register: homeserver is up after ${waited}s"

waldur register_matrix_appservice --url "${CALLBACK_URL}"
