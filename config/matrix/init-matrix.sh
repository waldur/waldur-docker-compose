#!/usr/bin/env bash
# Bootstraps the Matrix add-on inside waldur-docker-compose.
#
# Idempotent: generates AS/HS/registration tokens once into a shared volume,
# renders the tuwunel.toml and the appservice descriptor that Tuwunel
# operators paste into the !admin admin room, then seeds Constance via the
# existing `override_constance_settings` management command (same pattern
# as init-whitelabeling).

set -euo pipefail

TEMPLATES=/etc/waldur/matrix
SHARED=/var/lib/waldur/matrix
SECRETS="${SHARED}/secrets.env"

mkdir -p "${SHARED}"

if [[ ! -f "${SECRETS}" ]]; then
	AS_TOKEN="$(openssl rand -hex 32)"
	HS_TOKEN="$(openssl rand -hex 32)"
	REG_TOKEN="$(openssl rand -hex 32)"
	umask 077
	cat > "${SECRETS}" <<-EOF
		AS_TOKEN=${AS_TOKEN}
		HS_TOKEN=${HS_TOKEN}
		REG_TOKEN=${REG_TOKEN}
	EOF
	echo "matrix-init: generated fresh AS/HS/registration tokens"
else
	echo "matrix-init: reusing existing tokens from ${SECRETS}"
fi

# shellcheck disable=SC1090
source "${SECRETS}"

SERVER_NAME="${WALDUR_DOMAIN:-localhost}"
LOCALPART="${WALDUR_MATRIX_BOT_LOCALPART:-waldur-bot}"
OPEN_REG="${WALDUR_MATRIX_OPEN_REGISTRATION:-false}"
RTC_ENABLED="${WALDUR_MATRIX_RTC_ENABLED:-false}"

if [[ "${RTC_ENABLED}" == "true" ]]; then
	RTC_BLOCK=$'[[global.well_known.rtc_transports]]\ntype = "livekit"\nlivekit_service_url = "https://'"${SERVER_NAME}"$'/lk-jwt"'
else
	RTC_BLOCK=""
fi

# Render tuwunel.toml
sed \
	-e "s|@@SERVER_NAME@@|${SERVER_NAME}|g" \
	-e "s|@@REG_TOKEN@@|${REG_TOKEN}|g" \
	-e "s|@@OPEN_REGISTRATION@@|${OPEN_REG}|g" \
	"${TEMPLATES}/tuwunel.toml.template" > "${SHARED}/tuwunel.toml.tmp"
# Inject the RTC block via awk to keep multi-line replacement readable
awk -v block="${RTC_BLOCK}" '{ gsub(/@@RTC_BLOCK@@/, block); print }' \
	"${SHARED}/tuwunel.toml.tmp" > "${SHARED}/tuwunel.toml"
rm -f "${SHARED}/tuwunel.toml.tmp"

# Render appservice descriptor (the YAML the operator pastes into Tuwunel's
# admin room via `!admin appservices register`).
sed \
	-e "s|@@AS_TOKEN@@|${AS_TOKEN}|g" \
	-e "s|@@HS_TOKEN@@|${HS_TOKEN}|g" \
	-e "s|@@SERVER_NAME@@|${SERVER_NAME}|g" \
	-e "s|@@LOCALPART@@|${LOCALPART}|g" \
	"${TEMPLATES}/waldur-registration.yaml.template" > "${SHARED}/waldur-registration.yaml"

# Render Constance overrides and apply via the existing management command.
# Backend bot HTTP calls use MATRIX_HOMESERVER_URL (Docker DNS, internal).
# Browser clients reach the homeserver via Caddy at MATRIX_HOMESERVER_PUBLIC_URL
# — Django URLValidator rejects single-word hostnames so the internal value
# uses the `tuwunel.internal` network alias defined in docker-compose.yml.
CONSTANCE_YAML="$(mktemp)"
cat > "${CONSTANCE_YAML}" <<-EOF
	MATRIX_ENABLED: true
	MATRIX_HOMESERVER_URL: http://tuwunel.internal:6167
	MATRIX_HOMESERVER_PUBLIC_URL: https://${SERVER_NAME}
	MATRIX_HOMESERVER_DOMAIN: ${SERVER_NAME}
	MATRIX_APPSERVICE_AS_TOKEN: ${AS_TOKEN}
	MATRIX_APPSERVICE_HS_TOKEN: ${HS_TOKEN}
	MATRIX_APPSERVICE_SENDER_LOCALPART: ${LOCALPART}
	MATRIX_USER_REGISTRATION_SECRET: ${REG_TOKEN}
EOF

waldur override_constance_settings "${CONSTANCE_YAML}"
rm -f "${CONSTANCE_YAML}"

echo "matrix-init: Constance seeded. Rendered files in ${SHARED}:"
ls -l "${SHARED}"
echo "matrix-init: appservice descriptor at ${SHARED}/waldur-registration.yaml — paste this into Tuwunel's admin room via '!admin appservices register'"
