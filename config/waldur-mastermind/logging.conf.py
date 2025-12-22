# Empty logging configuration - uses defaults from Docker image
# Located at: docker/rootfs/etc/waldur/logging.conf.py in the main repository
#
# To customize logging, uncomment and modify the LOGGING dictionary below:
#
# import sys
#
# LOGGING = {
#     'version': 1,
#     'disable_existing_loggers': False,
#     'formatters': {
#         'simple': {
#             'format': '%(asctime)s %(levelname)s %(message)s',
#         },
#     },
#     'handlers': {
#         'console': {
#             'class': 'logging.StreamHandler',
#             'formatter': 'simple',
#             'level': 'DEBUG',
#             'stream': sys.stdout,
#         },
#     },
#     'root': {
#         'level': 'DEBUG',
#         'handlers': ['console'],
#     },
# }
