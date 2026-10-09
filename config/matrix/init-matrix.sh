#!/usr/bin/env bash
# Bootstraps the Matrix add-on inside waldur-docker-compose.
#
# Idempotent: generates AS/HS/registration tokens once into a shared volume,
# renders the tuwunel.toml, seeds Constance via mastermind's
# `init_matrix_settings` management command, and renders the appservice
# descriptor that operators register in Tuwunel's admin room with
# `!admin appservices register` (see docs/matrix-chat-add-on.md).

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

# A hand-edited file (a rotation) could lose a key; seeding an empty token
# would only fail later, as M_UNKNOWN_TOKEN on every bot call.
for key in AS_TOKEN HS_TOKEN REG_TOKEN; do
	if [[ -z "${!key:-}" ]]; then
		echo "matrix-init: ${SECRETS} has no ${key}; restore it or remove the file to generate new tokens" >&2
		exit 1
	fi
done

SERVER_NAME="${WALDUR_DOMAIN:-localhost}"
LOCALPART="${WALDUR_MATRIX_BOT_LOCALPART:-waldur-bot}"
OPEN_REG="${WALDUR_MATRIX_OPEN_REGISTRATION:-false}"
RTC_ENABLED="${WALDUR_MATRIX_RTC_ENABLED:-false}"

# Calls: the homeserver's .well-known points Matrix clients (Element and
# Waldur's chat drawer) at Waldur's call token API, served by the same Caddy
# site. Waldur gives a LiveKit token only to joined members of the room.
if [[ "${RTC_ENABLED}" == "true" ]]; then
	RTC_BLOCK=$'[[global.well_known.rtc_transports]]\ntype = "livekit"\nlivekit_service_url = "https://'"${SERVER_NAME}"$'/api/matrix/livekit"'
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
#   * it refuses to replace appservice tokens that were configured by hand
#     (through the Setup wizard), which the homeserver may be registered with.
#
# Exported rather than written to a file because these are generated secrets,
# and the exports live only in this process, not in the container's config.
#
# Backend bot HTTP calls use MATRIX_HOMESERVER_URL (Docker DNS, internal).
# Browser clients reach the homeserver via Caddy at MATRIX_HOMESERVER_PUBLIC_URL
# — Django URLValidator rejects single-word hostnames so the internal value
# uses the `tuwunel.internal` network alias defined in docker-compose.yml.
#
# MATRIX_ENABLED is deliberately not exported. `init_matrix_settings` switches
# chat on at the first seed (while MATRIX_TOKENS_MANAGED_BY is blank and no
# appservice token is stored) and leaves it alone on every later run, but an
# environment value applies on every run: an admin who turned chat off would
# find it back on after the next `up`.
export MATRIX_HOMESERVER_URL=http://tuwunel.internal:6167
export MATRIX_HOMESERVER_PUBLIC_URL="https://${SERVER_NAME}"
export MATRIX_HOMESERVER_DOMAIN="${SERVER_NAME}"
export MATRIX_APPSERVICE_AS_TOKEN="${AS_TOKEN}"
export MATRIX_APPSERVICE_HS_TOKEN="${HS_TOKEN}"
export MATRIX_APPSERVICE_SENDER_LOCALPART="${LOCALPART}"
export MATRIX_USER_REGISTRATION_SECRET="${REG_TOKEN}"

waldur init_matrix_settings

# LiveKit settings Waldur issues call tokens with: the signaling URL browsers
# dial through Caddy, the room API on the `livekit.internal` alias, and the
# key and secret LiveKit verifies the tokens with. JSON is valid YAML and
# quotes whatever the key and secret contain. Piped rather than written to a
# temp file, so the secret never lands on disk.
if [[ "${RTC_ENABLED}" == "true" ]]; then
	MATRIX_LIVEKIT_PUBLIC_URL="wss://${SERVER_NAME}/livekit" \
		python3 -c 'import json, os; print(json.dumps({
	"MATRIX_LIVEKIT_PUBLIC_URL": os.environ["MATRIX_LIVEKIT_PUBLIC_URL"],
	"MATRIX_LIVEKIT_URL": "http://livekit.internal:7880",
	"MATRIX_LIVEKIT_KEY": os.environ.get("WALDUR_LIVEKIT_KEY") or "devkey",
	"MATRIX_LIVEKIT_SECRET": os.environ.get("WALDUR_LIVEKIT_SECRET") or "devsecret",
}))' | waldur override_constance_settings /dev/stdin
fi

# The descriptor to register in Tuwunel's admin room. Rendered by mastermind
# from the settings just seeded, so it declares the namespaces Waldur uses,
# room aliases included.
#
# A failure here is a warning: it must not keep Tuwunel from starting.
# Rendered to a temporary file and checked before it replaces the old one.
# Mastermind logs to stdout too, as one JSON object per line (a warning about
# FIELD_ENCRYPTION_KEY, say), so those lines are dropped and the rest must
# parse as the descriptor.
DESCRIPTOR="${SHARED}/waldur-registration.yaml"
umask 077
if waldur generate_appservice_registration \
	--url "${WALDUR_MATRIX_APPSERVICE_URL:-http://waldur-mastermind-api:8080}" \
	> "${DESCRIPTOR}.out" &&
	python3 -c '
import json, sys, yaml

def is_log(line):
    try:
        return isinstance(json.loads(line), dict)
    except ValueError:
        return False

with open(sys.argv[1]) as f:
    text = "".join(line for line in f if not is_log(line))
doc = yaml.safe_load(text)
if not (isinstance(doc, dict) and doc.get("id") == "waldur"):
    sys.exit(1)
with open(sys.argv[2], "w") as f:
    f.write(text)
' "${DESCRIPTOR}.out" "${DESCRIPTOR}.tmp" 2>/dev/null; then
	rm -f "${DESCRIPTOR}.out"
	mv "${DESCRIPTOR}.tmp" "${DESCRIPTOR}"
	echo "matrix-init: appservice descriptor at ${DESCRIPTOR} — register it in Tuwunel's admin room with '!admin appservices register'"
else
	# An older descriptor may hold tokens that were rotated since; registering
	# it would put the homeserver and Waldur out of step again.
	rm -f "${DESCRIPTOR}.out" "${DESCRIPTOR}.tmp" "${DESCRIPTOR}"
	echo "matrix-init: WARNING: could not render the appservice descriptor, so ${DESCRIPTOR} is absent; see the waldur-matrix-init log" >&2
fi

echo "matrix-init: Constance seeded. Rendered files in ${SHARED}:"
ls -l "${SHARED}"
