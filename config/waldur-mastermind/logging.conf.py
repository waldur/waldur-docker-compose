# Logging customisation for this deployment. Empty by default.
#
# The logging configuration lives in mastermind's
# waldur_core/server/base_settings.py and every deployment gets it, so there is
# nothing to repeat here. It sends JSON to stdout, and quiets loggers that would
# otherwise flood: the neutronclient deprecation notice (one line per client,
# several per tenant on every OpenStack pull), Celery's import and boot
# machinery, django_structlog's per-request INFO pairs, and axes.
#
# This file is exec'd by /etc/waldur/settings.py *after* those base settings, so
# ASSIGNING `LOGGING` here replaces the whole configuration and silently discards
# all of the above. Mutate it in place instead:
#
# # Raise one logger's verbosity.
# LOGGING['loggers']['waldur_openstack'] = {'level': 'DEBUG'}
#
# # Add a handler and route a logger to it. 'structlog_json' and
# # 'structlog_console' are the formatters the base settings define.
# LOGGING['handlers']['file'] = {
#     'class': 'logging.handlers.WatchedFileHandler',
#     'filename': '/var/log/waldur/debug.log',
#     'formatter': 'structlog_json',
# }
# LOGGING['loggers']['waldur_core'] = {
#     'handlers': ['console', 'file'],
#     'level': 'DEBUG',
#     'propagate': False,
# }
#
# For readable console output instead of JSON while debugging, set
# WALDUR_DEV_LOGS=1 in the environment rather than editing this file.
