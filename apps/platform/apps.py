from __future__ import annotations

from django.apps import AppConfig


class PlatformConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.platform"
    label = "platform_core"
    verbose_name = "Platform"
