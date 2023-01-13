WALDUR_CORE['AUTHENTICATION_METHODS'] = ["LOCAL_SIGNIN", "SOCIAL_SIGNUP"]

WALDUR_CORE['SITE_NAME'] = 'test'

WALDUR_CORE['SITE_LOGO'] = '/etc/waldur/logo.png'

WALDUR_CORE['CREATE_DEFAULT_PROJECT_ON_ORGANIZATION_CREATION'] = True

# Disable geoip location till HomePort releases maps to a stable deployment
WALDUR_CORE['ENABLE_GEOIP'] = False

WALDUR_CORE['HOMEPORT_SENTRY_ENVIRONMENT'] = env.get('SENTRY_ENVIRONMENT', 'waldur-production')

WALDUR_AUTH_SOCIAL.update({'KEYCLOAK_AUTH_URL': '/auth/realms/Waldur/protocol/openid-connect/auth',
 'KEYCLOAK_CLIENT_ID': 'waldur',
 'KEYCLOAK_SECRET': env.get('KEYCLOAK_SECRET'),
 'KEYCLOAK_TOKEN_URL': 'http://keycloak:8080/auth/realms/Waldur/protocol/openid-connect/token',
 'KEYCLOAK_USERINFO_URL': 'http://keycloak:8080/auth/realms/Waldur/protocol/openid-connect/userinfo'
})
