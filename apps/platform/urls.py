from __future__ import annotations

from django.urls import path

from apps.platform import views

app_name = "platform"

urlpatterns = [
    path("live/", views.liveness, name="liveness"),
    path("ready/", views.readiness, name="readiness"),
]
