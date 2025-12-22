import sys


LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,

    'formatters': {
        'simple': {
            'format': '%(asctime)s %(levelname)s %(message)s',
        },
    },

    'handlers': {
        'console': {
            'class': 'logging.StreamHandler',
            'formatter': 'simple',
            'level': 'DEBUG',
            'stream': sys.stdout,
        },
    },

    'loggers': {
        # Suppress excessive Celery task registration logging
        'celery.utils.imports': {
            'level': 'WARNING',
            'handlers': ['console'],
            'propagate': False,
        },
        'celery.app.autodiscover': {
            'level': 'WARNING',
            'handlers': ['console'],
            'propagate': False,
        },
    },

    'root': {
        'level': 'DEBUG',
        'handlers': ['console'],
    },
}
