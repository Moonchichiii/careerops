from __future__ import annotations

from .base import *  # noqa: F403
from .base import env

DEBUG = False
SECRET_KEY = "careerops-tests-only-secret-key"
ALLOWED_HOSTS = ["testserver", "localhost"]

DATABASES = {
    "default": env.db_url(
        "TEST_DATABASE_URL",
        default="postgresql://careerops:careerops@127.0.0.1:55432/careerops",
    ),
}
DATABASES["default"]["CONN_MAX_AGE"] = 0
DATABASES["default"]["CONN_HEALTH_CHECKS"] = True

EMAIL_BACKEND = "django.core.mail.backends.locmem.EmailBackend"
