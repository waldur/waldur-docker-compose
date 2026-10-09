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
LOGIN_WITH_PASSWORD="${WALDUR_MATRIX_LOGIN_WITH_PASSWORD:-true}"
if [[ "${LOGIN_WITH_PASSWORD}" != "true" && "${LOGIN_WITH_PASSWORD}" != "false" ]]; then
	echo "matrix-init: WALDUR_MATRIX_LOGIN_WITH_PASSWORD must be true or false" >&2
	exit 1
fi
SSO_ENABLED="${WALDUR_MATRIX_SSO_ENABLED:-false}"
if [[ "${SSO_ENABLED}" != "true" && "${SSO_ENABLED}" != "false" ]]; then
	echo "matrix-init: WALDUR_MATRIX_SSO_ENABLED must be true or false" >&2
	exit 1
fi
# Checked before anything is rendered, so a refused run leaves the previous
# configuration in place rather than one with single sign-on dropped. The
# values are written into tuwunel.toml as they are, so anything that could
# end a TOML string is refused rather than escaped.
FORBIDDEN_USERNAMES=""
if [[ "${SSO_ENABLED}" == "true" ]]; then
	: "${WALDUR_MATRIX_SSO_ISSUER_URL:?matrix-init: set WALDUR_MATRIX_SSO_ISSUER_URL for single sign-on}"
	: "${WALDUR_MATRIX_SSO_CLIENT_ID:?matrix-init: set WALDUR_MATRIX_SSO_CLIENT_ID for single sign-on}"
	: "${WALDUR_MATRIX_SSO_CLIENT_SECRET:?matrix-init: set WALDUR_MATRIX_SSO_CLIENT_SECRET for single sign-on}"
	SSO_NAME="${WALDUR_MATRIX_SSO_NAME:-Single sign-on}"
	SSO_BRAND="${WALDUR_MATRIX_SSO_BRAND:-keycloak}"
	SSO_CLAIM="${WALDUR_MATRIX_SSO_USERID_CLAIM:-sub}"
	if [[ "${SSO_NAME}" =~ [\"\\[:cntrl:]] ]]; then
		echo "matrix-init: WALDUR_MATRIX_SSO_NAME may not contain quotes, backslashes or control characters" >&2
		exit 1
	fi
	if [[ ! "${WALDUR_MATRIX_SSO_CLIENT_ID}" =~ ^[A-Za-z0-9._-]+$ ]]; then
		echo "matrix-init: WALDUR_MATRIX_SSO_CLIENT_ID may contain only letters, digits, '.', '_' and '-'" >&2
		exit 1
	fi
	if [[ ! "${SSO_BRAND}" =~ ^[A-Za-z0-9._-]+$ ]]; then
		echo "matrix-init: WALDUR_MATRIX_SSO_BRAND may contain only letters, digits, '.', '_' and '-'" >&2
		exit 1
	fi
	if [[ ! "${WALDUR_MATRIX_SSO_ISSUER_URL}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/:@=+-]*)?$ ]]; then
		echo "matrix-init: WALDUR_MATRIX_SSO_ISSUER_URL must be an https:// URL, without query or fragment" >&2
		exit 1
	fi
	# The claims Tuwunel can take a username from.
	case "${SSO_CLAIM}" in
	sub | preferred_username | username | nickname | email | login) ;;
	*)
		echo "matrix-init: WALDUR_MATRIX_SSO_USERID_CLAIM must be one of sub, preferred_username, username, nickname, email, login" >&2
		exit 1
		;;
	esac
	# Tuwunel takes only the local part of an email claim, so alice@a.org and
	# alice@b.org would sign in to the same account.
	ALLOW_EMAIL_CLAIM="${WALDUR_MATRIX_SSO_ALLOW_EMAIL_CLAIM:-false}"
	if [[ "${SSO_CLAIM}" == "email" && "${ALLOW_EMAIL_CLAIM}" != "true" ]]; then
		echo "matrix-init: WALDUR_MATRIX_SSO_USERID_CLAIM=email uses only the local part of the address, so alice@a.org and alice@b.org would sign in to the same account. Use another claim, or set WALDUR_MATRIX_SSO_ALLOW_EMAIL_CLAIM=true if the IdP issues addresses of a single domain." >&2
		exit 1
	fi
	# A trusted provider signs in to any existing account named like the claim,
	# so with open registration anyone could register @bob first and receive
	# bob's single sign-on.
	if [[ "${OPEN_REG}" != "false" ]]; then
		echo "matrix-init: WALDUR_MATRIX_SSO_ENABLED=true cannot be combined with WALDUR_MATRIX_OPEN_REGISTRATION=${OPEN_REG}: anyone could register an account named like another user's claim and receive that user's single sign-on. Set WALDUR_MATRIX_OPEN_REGISTRATION=false." >&2
		exit 1
	fi
	# A trusted provider signs in to any existing account its claim names, so
	# the bot's account, waldur-bootstrap (reserved for the bootstrap admin that
	# automatic registration will create) and any other admin are kept out of
	# its reach.
	FORBIDDEN_EXTRA="${WALDUR_MATRIX_SSO_FORBIDDEN_USERNAMES:-}"
	if [[ ! "${LOCALPART}" =~ ^[a-z0-9._=/+-]+$ ]]; then
		echo "matrix-init: WALDUR_MATRIX_BOT_LOCALPART must be a Matrix localpart (a-z 0-9 . _ = / + -)" >&2
		exit 1
	fi
	if [[ -n "${FORBIDDEN_EXTRA}" && ! "${FORBIDDEN_EXTRA}" =~ ^[a-z0-9._=/+-]+(\ *,\ *[a-z0-9._=/+-]+)*$ ]]; then
		echo "matrix-init: WALDUR_MATRIX_SSO_FORBIDDEN_USERNAMES must be comma-separated Matrix localparts (a-z 0-9 . _ = / + -)" >&2
		exit 1
	fi
	read -ra FORBIDDEN <<<"${LOCALPART} waldur-bootstrap ${FORBIDDEN_EXTRA//,/ }"
	for name in "${FORBIDDEN[@]}"; do
		# Anchored, since Tuwunel forbids every username a pattern occurs in;
		# "." and "+" are regex syntax.
		name="${name//./[.]}"
		FORBIDDEN_USERNAMES+="${FORBIDDEN_USERNAMES:+, }\"^${name//+/[+]}\$\""
	done
	FORBIDDEN_USERNAMES="forbidden_usernames = [${FORBIDDEN_USERNAMES}]"
fi

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
	-e "s|@@LOGIN_WITH_PASSWORD@@|${LOGIN_WITH_PASSWORD}|g" \
	-e "s|@@FORBIDDEN_USERNAMES@@|${FORBIDDEN_USERNAMES}|g" \
	"${TEMPLATES}/tuwunel.toml.template" > "${SHARED}/tuwunel.toml.tmp"
# Inject the RTC block via awk to keep multi-line replacement readable
awk -v block="${RTC_BLOCK}" '{ gsub(/@@RTC_BLOCK@@/, block); print }' \
	"${SHARED}/tuwunel.toml.tmp" > "${SHARED}/tuwunel.toml"
rm -f "${SHARED}/tuwunel.toml.tmp"

# Single sign-on for Matrix clients (MATRIX_EXTERNAL_LOGIN_METHOD=oidc). With
# trusted, a claim that matches an existing account signs in to it, the one
# Waldur provisioned, instead of registering a second one. The client secret
# stays out of tuwunel.toml: the homeserver reads it from a file.
SSO_SECRET_FILE="${SHARED}/sso_client_secret"
if [[ "${SSO_ENABLED}" == "true" ]]; then
	(umask 077 && printf '%s' "${WALDUR_MATRIX_SSO_CLIENT_SECRET}" > "${SSO_SECRET_FILE}")
	cat >> "${SHARED}/tuwunel.toml" <<-EOF

		[[global.identity_provider]]
		brand = "${SSO_BRAND}"
		name = "${SSO_NAME}"
		client_id = "${WALDUR_MATRIX_SSO_CLIENT_ID}"
		client_secret_file = "/etc/waldur/matrix/sso_client_secret"
		issuer_url = "${WALDUR_MATRIX_SSO_ISSUER_URL}"
		callback_url = "https://${SERVER_NAME}/_matrix/client/unstable/login/sso/callback/${WALDUR_MATRIX_SSO_CLIENT_ID}"
		userid_claims = ["${SSO_CLAIM}"]
		trusted = true
		unique_id_fallbacks = false
		registration = false
	EOF
	echo "matrix-init: single sign-on for Matrix clients via ${WALDUR_MATRIX_SSO_ISSUER_URL}"
else
	rm -f "${SSO_SECRET_FILE}"
fi

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
