from __future__ import annotations

from django.urls import path

from apps.accounts.views import SessionLoginView, SessionLogoutView

app_name = "accounts"

urlpatterns = [
    path("login/", SessionLoginView.as_view(), name="login"),
    path("logout/", SessionLogoutView.as_view(), name="logout"),
]
