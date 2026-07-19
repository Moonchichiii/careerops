from __future__ import annotations

from django.contrib import admin
from django.urls import include, path

from apps.platform import views

urlpatterns = [
    path("", views.shell, name="shell"),
    path("account/", include("apps.accounts.urls")),
    path("admin/", admin.site.urls),
    path("_assets/smoke/", views.asset_smoke, name="asset-smoke"),
    path("health/", include("apps.platform.urls")),
]
