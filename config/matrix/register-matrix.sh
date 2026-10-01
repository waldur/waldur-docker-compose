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

# `depends_on` only waits for Tuwunel to start. Its image health check would
# mark a homeserver that is still migrating unhealthy and fail the whole `up`,
# so wait for the client API to answer instead.
#
# The wait has to outlast a database migration: Tuwunel migrates its embedded
# database in place before it opens the listener, prints nothing while doing
# so, and the time scales with the size of the tuwunel_data volume. This
# container is `restart: "no"`, so giving up too early fails the registration
# for the whole `up`. The cap is only a backstop against a homeserver that will
# never come up; raise it rather than lowering it.
WAIT_LIMIT="${WALDUR_MATRIX_REGISTER_WAIT_SECONDS:-3600}"
if [[ ! "${WAIT_LIMIT}" =~ ^[0-9]+$ ]]; then
	echo "matrix-register: WALDUR_MATRIX_REGISTER_WAIT_SECONDS must be a whole number of seconds, got '${WAIT_LIMIT}'" >&2
	exit 1
fi
# Base 10 explicitly: bash reads a leading zero as octal, and "08" is not one.
WAIT_LIMIT=$((10#${WAIT_LIMIT}))

# Wall-clock time, not a count of sleeps: a probe against a homeserver that
# accepts the connection but does not answer takes its full 5 s timeout, so
# counting sleeps would stretch the limit several times over.
SECONDS=0
next_note=30
echo "matrix-register: waiting up to ${WAIT_LIMIT}s for ${HOMESERVER} to accept requests"
until python3 -c "
import sys, urllib.request
try:
    urllib.request.urlopen('${HOMESERVER}/_matrix/client/versions', timeout=5)
except Exception:
    sys.exit(1)
" 2>/dev/null; do
	if (( SECONDS >= WAIT_LIMIT )); then
		echo "matrix-register: homeserver did not become reachable within ${WAIT_LIMIT}s (WALDUR_MATRIX_REGISTER_WAIT_SECONDS)" >&2
		exit 1
	fi
	if (( SECONDS >= next_note )); then
		echo "matrix-register: still waiting (${SECONDS}s) — a silent homeserver is migrating its database, not hung"
		next_note=$((next_note + 30))
	fi
	sleep 2
done
echo "matrix-register: homeserver is up after ${SECONDS}s"

# The command ends by asking the homeserver to ping Waldur at CALLBACK_URL. An
# `up` that recreates the API (every image bump) runs this before gunicorn
# listens, so that ping would report a broken callback on a healthy upgrade.
# Any HTTP answer will do: the endpoint rejects an unauthenticated probe, and an
# https URL behind Caddy's internal CA would never verify. Not waiting forever:
# the command still registers, and only warns about the ping.
API_WAIT_LIMIT=300
SECONDS=0
until python3 -c "
import ssl, sys, urllib.error, urllib.request
try:
    urllib.request.urlopen('${CALLBACK_URL}/_matrix/app/v1/ping', timeout=5, context=ssl._create_unverified_context())
except urllib.error.HTTPError:
    pass
except Exception:
    sys.exit(1)
" 2>/dev/null; do
	if (( SECONDS >= API_WAIT_LIMIT )); then
		echo "matrix-register: Waldur did not answer at ${CALLBACK_URL} within ${API_WAIT_LIMIT}s; registering anyway"
		break
	fi
	sleep 2
done

# Read on its own rather than sourcing the file, which also holds the tokens
# this command takes from Constance.
SECRETS=/var/lib/waldur/matrix/secrets.env
MATRIX_BOOTSTRAP_PASSWORD="$(sed -n 's/^BOOTSTRAP_PASSWORD=//p' "${SECRETS}")"
export MATRIX_BOOTSTRAP_PASSWORD

# Compose always defines WALDUR_MATRIX_ADMIN_TOKEN, empty unless the operator
# passed one. Exported only when set, so an empty value can never stand in for
# "use this admin" and the command falls back to the bootstrap account.
if [[ -n "${WALDUR_MATRIX_ADMIN_TOKEN:-}" ]]; then
	export MATRIX_ADMIN_TOKEN="${WALDUR_MATRIX_ADMIN_TOKEN}"
fi

waldur register_matrix_appservice --url "${CALLBACK_URL}"
