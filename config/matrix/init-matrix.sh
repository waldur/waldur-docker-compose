#!/usr/bin/env bash
# Bootstraps the Matrix add-on inside waldur-docker-compose.
#
# Idempotent: generates AS/HS/registration tokens once into a shared volume,
# renders the tuwunel.toml and the appservice descriptor, then seeds Constance
# via mastermind's `init_matrix_settings` management command.
#
# This is the first half of the Matrix bootstrap. The descriptor it renders is
# submitted to the homeserver by the waldur-matrix-register container, which
# runs after Tuwunel is up — see register-matrix.sh.

set -euo pipefail

TEMPLATES=/etc/waldur/matrix
SHARED=/var/lib/waldur/matrix
SECRETS="${SHARED}/secrets.env"

mkdir -p "${SHARED}"

if [[ ! -f "${SECRETS}" ]]; then
	AS_TOKEN="$(openssl rand -hex 32)"
	HS_TOKEN="$(openssl rand -hex 32)"
	REG_TOKEN="$(openssl rand -hex 32)"
	# Password of the homeserver admin that waldur-matrix-register creates, so
	# later runs can log back in and apply rotated tokens.
	BOOTSTRAP_PASSWORD="$(openssl rand -hex 32)"
	umask 077
	cat > "${SECRETS}" <<-EOF
		AS_TOKEN=${AS_TOKEN}
		HS_TOKEN=${HS_TOKEN}
		REG_TOKEN=${REG_TOKEN}
		BOOTSTRAP_PASSWORD=${BOOTSTRAP_PASSWORD}
	EOF
	echo "matrix-init: generated fresh AS/HS/registration tokens and bootstrap password"
else
	echo "matrix-init: reusing existing tokens from ${SECRETS}"
	if ! grep -q '^BOOTSTRAP_PASSWORD=' "${SECRETS}"; then
		# A stack set up before the bootstrap password existed. The register
		# command expects one on every stack, so add it. It does not make
		# rotation automatic here: this homeserver's admin was created some
		# other way, so rotating tokens or applying a changed descriptor still
		# needs that admin's access token.
		if [[ -s "${SECRETS}" && -n "$(tail -c 1 "${SECRETS}")" ]]; then
			echo >> "${SECRETS}"
		fi
		echo "BOOTSTRAP_PASSWORD=$(openssl rand -hex 32)" >> "${SECRETS}"
		echo "matrix-init: added BOOTSTRAP_PASSWORD to ${SECRETS}. This stack predates it, so its homeserver admin does not use it: registration keeps working, but rotating tokens or applying a changed descriptor needs that admin's access token (WALDUR_MATRIX_ADMIN_TOKEN), see \"Stacks registered by hand\" in docs/matrix-chat-add-on.md"
	fi
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

# Seed Constance through mastermind's `init_matrix_settings`, which the Helm
# chart calls with these same variable names. Two reasons it is not
# `override_constance_settings` like init-whitelabeling:
#
#   * that command drops any key the serializer rejects and still exits 0, so a
#     malformed URL or a truncated token brings the stack up looking configured
#     and fails every bot call later with M_UNKNOWN_TOKEN;
#   * the key list would live here, in a shell heredoc, and drift from the
#     backend. `init_matrix_settings` derives it from the Constance registry,
#     so a new MATRIX_* setting needs no edit in this repo.
#
# Exported rather than written to a file because these are generated secrets:
# `set -e` would skip a cleanup `rm` if the seeding step failed, leaving both
# appservice tokens on disk in the container.
#
# Backend bot HTTP calls use MATRIX_HOMESERVER_URL (Docker DNS, internal).
# Browser clients reach the homeserver via Caddy at MATRIX_HOMESERVER_PUBLIC_URL
# — Django URLValidator rejects single-word hostnames so the internal value
# uses the `tuwunel.internal` network alias defined in docker-compose.yml.
#
# MATRIX_ENABLED is deliberately not exported. `init_matrix_settings` switches
# chat on at the first seed (while MATRIX_TOKENS_MANAGED_BY is still blank) and
# leaves it alone on every later run, but an environment value applies on every
# run: an admin who turned chat off would find it back on after the next `up`.
export MATRIX_HOMESERVER_URL=http://tuwunel.internal:6167
export MATRIX_HOMESERVER_PUBLIC_URL="https://${SERVER_NAME}"
export MATRIX_HOMESERVER_DOMAIN="${SERVER_NAME}"
export MATRIX_APPSERVICE_AS_TOKEN="${AS_TOKEN}"
export MATRIX_APPSERVICE_HS_TOKEN="${HS_TOKEN}"
export MATRIX_APPSERVICE_SENDER_LOCALPART="${LOCALPART}"
export MATRIX_USER_REGISTRATION_SECRET="${REG_TOKEN}"

# The command refuses to overwrite appservice tokens that differ from these and
# that no deployment seeded (rotated in the Setup wizard, say): chat would break
# until the homeserver got a new registration. WALDUR_MATRIX_ADOPT_TOKENS=true
# overrides that, meant for a single `up`; left on, it would also overwrite the
# next tokens changed outside compose without asking.
if [[ "${WALDUR_MATRIX_ADOPT_TOKENS:-}" == "true" ]]; then
	waldur init_matrix_settings --adopt
else
	waldur init_matrix_settings
fi

# The descriptor for registering by hand (see docs/matrix-chat-add-on.md).
# Rendered by mastermind from the settings just seeded, so it declares the same
# namespaces as what waldur-matrix-register sends, room aliases included.
#
# Only the manual path reads it, so a failure here is a warning: it must not
# keep Tuwunel from starting. Rendered to a temporary file and checked before it
# replaces the old one, because mastermind logs to stdout too, and one stray log
# line would turn the YAML into something the homeserver rejects.
DESCRIPTOR="${SHARED}/waldur-registration.yaml"
umask 077
if waldur generate_appservice_registration \
	--url "${WALDUR_MATRIX_APPSERVICE_URL:-http://waldur-mastermind-api:8080}" \
	> "${DESCRIPTOR}.tmp" &&
	python3 -c '
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
sys.exit(0 if isinstance(doc, dict) and doc.get("id") == "waldur" else 1)
' "${DESCRIPTOR}.tmp" 2>/dev/null; then
	mv "${DESCRIPTOR}.tmp" "${DESCRIPTOR}"
	echo "matrix-init: appservice descriptor at ${DESCRIPTOR} — registered automatically by the waldur-matrix-register container; only needed by hand if WALDUR_MATRIX_REGISTER_APPSERVICE=false"
else
	# An older descriptor may hold tokens that were rotated since; registering
	# it by hand would put the homeserver and Waldur out of step again.
	rm -f "${DESCRIPTOR}.tmp" "${DESCRIPTOR}"
	echo "matrix-init: WARNING: could not render the appservice descriptor, so ${DESCRIPTOR} is absent. Automatic registration does not need it; registering by hand does." >&2
fi

echo "matrix-init: Constance seeded. Rendered files in ${SHARED}:"
ls -l "${SHARED}"
