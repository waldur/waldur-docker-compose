WALDUR_CORE['AUTHENTICATION_METHODS'] = ["LOCAL_SIGNIN", "SOCIAL_SIGNUP"]

WALDUR_CORE['SITE_NAME'] = 'test'

WALDUR_CORE['SITE_LOGO'] = '/etc/waldur/logo.png'

WALDUR_CORE['CREATE_DEFAULT_PROJECT_ON_ORGANIZATION_CREATION'] = True

# Disable geoip location till HomePort releases maps to a stable deployment
WALDUR_CORE['ENABLE_GEOIP'] = False

WALDUR_CORE['HOMEPORT_SENTRY_ENVIRONMENT'] = env.get('SENTRY_ENVIRONMENT', 'waldur-production')
