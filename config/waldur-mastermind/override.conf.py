import os

WALDUR_CORE['AUTHENTICATION_METHODS'] = ["LOCAL_SIGNIN", "SOCIAL_SIGNUP"]

WALDUR_CORE['CREATE_DEFAULT_PROJECT_ON_ORGANIZATION_CREATION'] = True

WALDUR_CORE['HOMEPORT_SENTRY_ENVIRONMENT'] = env.get('SENTRY_ENVIRONMENT', 'waldur-production')

RABBITMQ_HOST = os.environ.get('RABBITMQ_HOST')
RABBITMQ_USER = os.environ.get('RABBITMQ_USERNAME')
RABBITMQ_PASSWORD = os.environ.get('RABBITMQ_PASSWORD')
RABBITMQ_PORT = "5672"
POSTGRESQL_HOST = os.environ.get('POSTGRESQL_HOST')
POSTGRESQL_PORT = "5432"
POSTGRESQL_PASSWORD = os.environ.get('POSTGRESQL_PASSWORD')
POSTGRESQL_NAME = 'celery_results'

CELERY_BROKER_URL = f'amqp://{RABBITMQ_USER}:{RABBITMQ_PASSWORD}@{RABBITMQ_HOST}:{RABBITMQ_PORT}'
CELERY_RESULT_BACKEND = f'db+postgresql+psycopg://waldur:{POSTGRESQL_PASSWORD}@{POSTGRESQL_HOST}:{POSTGRESQL_PORT}/{POSTGRESQL_NAME}'

CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.db.DatabaseCache',
        'LOCATION': 'waldur_cache',
        'OPTIONS': {
            # Django's own default is 300 rows, which is far too small: this
            # table holds the brute-force login lockout counters, the
            # blocked-user event dedup keys and the whole DRF throttle history,
            # and a third of it is deleted whenever it overflows. Left at the
            # default, those counters are evicted long before they expire and
            # the limits they implement quietly stop applying.
            'MAX_ENTRIES': 100000,
        },
    }
}

RABBITMQ = {
    "HOST": "waldur-queue",
    "STOMP_PORT": 61613,
    "USER": RABBITMQ_USER,
    "PASSWORD": RABBITMQ_PASSWORD,
    "MANAGEMENT_PORT": 15672,
}

# Outgoing email.
#
# The mastermind image ships an override.conf.py whose only content is a
# placeholder EMAIL_HOST; this file is mounted over it, so the SMTP settings
# have to be re-established here. They are read from the environment so that
# credentials stay in .env rather than in a file baked into the repository.
#
# Everything stays unset unless EMAIL_HOST is provided, which keeps Django's
# own defaults in place for stacks that do not send mail (demos, CI).
email_host = os.environ.get('EMAIL_HOST', '')
if email_host:
    EMAIL_HOST = email_host
    EMAIL_PORT = int(os.environ.get('EMAIL_PORT') or 25)
    EMAIL_HOST_USER = os.environ.get('EMAIL_USER', '')
    EMAIL_HOST_PASSWORD = os.environ.get('EMAIL_PASSWORD', '')
    # STARTTLS (typically port 587) and implicit TLS (typically port 465) are
    # mutually exclusive; Django raises at send time if both are enabled.
    EMAIL_USE_TLS = os.environ.get('EMAIL_USE_TLS', 'false').lower() == 'true'
    EMAIL_USE_SSL = os.environ.get('EMAIL_USE_SSL', 'false').lower() == 'true'
    # Without a timeout a stalled relay blocks a Celery worker indefinitely.
    EMAIL_TIMEOUT = int(os.environ.get('EMAIL_TIMEOUT') or 30)


# Native passkey (FIDO2/WebAuthn) support. Off unless WALDUR_PASSKEY_METHODS
# names at least one flow, so an existing deployment is unaffected.
#
#   WALDUR_PASSKEY_METHODS=PASSKEY_MFA              second factor after password
#   WALDUR_PASSKEY_METHODS=PASSKEY_SIGNIN           passwordless sign-in
#   WALDUR_PASSKEY_METHODS=PASSKEY_SIGNIN,PASSKEY_MFA  both
passkey_methods = [
    method.strip()
    for method in os.environ.get('WALDUR_PASSKEY_METHODS', '').split(',')
    if method.strip()
]
if passkey_methods:
    WALDUR_CORE['AUTHENTICATION_METHODS'] = (
        WALDUR_CORE['AUTHENTICATION_METHODS'] + passkey_methods
    )
    passkey_domain = os.environ.get('WALDUR_DOMAIN', 'localhost')
    # Caddy terminates TLS and serves the portal and the API on this one
    # origin, so both derive from the same value. Browsers expose WebAuthn
    # only in a secure context, which is why the origin is https even for
    # localhost, where Caddy uses its internal CA.
    #
    # CHANGING THE RP ID ORPHANS EVERY REGISTERED CREDENTIAL: a passkey is
    # bound to the domain it was created under, and after a change the browser
    # will not offer it. Waldur logs a startup warning counting the affected
    # credentials, but every user has to enrol again.
    WALDUR_CORE['PASSKEY_RP_ID'] = (
        os.environ.get('WALDUR_PASSKEY_RP_ID') or passkey_domain
    )
    passkey_origins = os.environ.get('WALDUR_PASSKEY_ALLOWED_ORIGINS', '')
    WALDUR_CORE['PASSKEY_ALLOWED_ORIGINS'] = [
        origin.strip() for origin in passkey_origins.split(',') if origin.strip()
    ] or [f'https://{passkey_domain}']
    passkey_rp_name = os.environ.get('WALDUR_PASSKEY_RP_NAME', '')
    if passkey_rp_name:
        WALDUR_CORE['PASSKEY_RP_NAME'] = passkey_rp_name
