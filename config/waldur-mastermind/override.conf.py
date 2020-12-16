WALDUR_CORE['AUTHENTICATION_METHODS'] = ["LOCAL_SIGNIN"]

WALDUR_CORE['SITE_NAME'] = 'test'

WALDUR_CORE['SITE_LOGO'] = '/etc/waldur/logo.png'

WALDUR_CORE['CREATE_DEFAULT_PROJECT_ON_ORGANIZATION_CREATION'] = True


# Disable company types till we start making use of them
WALDUR_CORE['COMPANY_TYPES'] = ()

# Disable geoip location till HomePort releases maps to a stable deployment
WALDUR_CORE['ENABLE_GEOIP'] = False

WALDUR_CORE['ALLOW_SIGNUP_WITHOUT_INVITATION'] = False
