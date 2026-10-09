#!/usr/bin/env bash
# Refuses LiveKit's development key and secret outside a local demo: anyone
# who knows them can mint a token for any call. livekit and lk-jwt-service
# wait for this check, so a refusal keeps both down and fails
# `docker compose up -d`; docs/matrix-chat-add-on.md says what else that can
# leave down.

set -euo pipefail

DOMAIN="${WALDUR_DOMAIN:-localhost}"
KEY="${WALDUR_LIVEKIT_KEY:-devkey}"
SECRET="${WALDUR_LIVEKIT_SECRET:-devsecret}"

case "${DOMAIN}" in
localhost | host.docker.internal) exit 0 ;;
esac

if [[ "${KEY}" == "devkey" || "${SECRET}" == "devsecret" || ${#SECRET} -lt 32 ]]; then
	echo "livekit-credentials-check: set WALDUR_LIVEKIT_KEY and WALDUR_LIVEKIT_SECRET (32+ characters) in .env; the development defaults let anyone join calls on ${DOMAIN}" >&2
	exit 1
fi
