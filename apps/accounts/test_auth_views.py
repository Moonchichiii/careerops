from __future__ import annotations

import importlib
import json
from typing import TYPE_CHECKING
from unittest.mock import patch

import pytest
from django.test import Client, override_settings
from django.urls import reverse

from apps.accounts.models import LoginThrottleState, User

if TYPE_CHECKING:
    from pathlib import Path

pytestmark = pytest.mark.django_db


def _valid_password() -> str:
    return "correct-horse-battery-staple"


def _write_manifest(directory: Path) -> Path:
    manifest_path = directory / "manifest.json"
    manifest_path.write_text(
        json.dumps(
            {
                "src/main.ts": {
                    "file": "assets/main-test.js",
                    "css": ["assets/main-test.css"],
                    "isEntry": True,
                }
            }
        ),
        encoding="utf-8",
    )
    return manifest_path


def test_anonymous_user_can_open_email_login_form(
    client: Client,
    tmp_path: Path,
) -> None:
    manifest_path = _write_manifest(tmp_path)

    with override_settings(
        VITE_MANIFEST_PATH=manifest_path,
        VITE_STATIC_PREFIX="careerops",
    ):
        response = client.get(reverse("accounts:login"))

    html = response.content.decode()

    assert response.status_code == 200
    assert "no-store" in response.headers["Cache-Control"]
    assert 'name="username"' in html
    assert 'type="email"' in html
    assert 'name="password"' in html
    assert 'name="csrfmiddlewaretoken"' in html


def test_user_can_log_in_and_log_out(
    client: Client,
) -> None:
    user = User.objects.create_user(
        email="mats@example.com",
        password=_valid_password(),
    )

    login_response = client.post(
        reverse("accounts:login"),
        {
            "username": user.email,
            "password": _valid_password(),
        },
    )

    assert login_response.status_code == 302
    assert login_response.headers["Location"] == reverse("shell")
    assert client.session["_auth_user_id"] == str(user.pk)

    logout_response = client.post(reverse("accounts:logout"))

    assert logout_response.status_code == 302
    assert logout_response.headers["Location"] == reverse("shell")
    assert "_auth_user_id" not in client.session


def test_login_rejects_invalid_credentials(
    client: Client,
    tmp_path: Path,
) -> None:
    User.objects.create_user(
        email="mats@example.com",
        password=_valid_password(),
    )
    manifest_path = _write_manifest(tmp_path)

    with override_settings(
        VITE_MANIFEST_PATH=manifest_path,
        VITE_STATIC_PREFIX="careerops",
    ):
        response = client.post(
            reverse("accounts:login"),
            {
                "username": "mats@example.com",
                "password": "incorrect-password",
            },
        )

    html = response.content.decode()

    assert response.status_code == 200
    assert "_auth_user_id" not in client.session
    assert 'class="auth-errors"' in html

    form = response.context["form"]
    non_field_errors = form.non_field_errors().as_data()

    assert len(non_field_errors) == 1
    assert non_field_errors[0].code == "invalid_login"


def test_login_does_not_redirect_to_external_host(
    client: Client,
) -> None:
    user = User.objects.create_user(
        email="mats@example.com",
        password=_valid_password(),
    )

    response = client.post(
        reverse("accounts:login"),
        {
            "username": user.email,
            "password": _valid_password(),
            "next": "https://attacker.example/phishing",
        },
    )

    assert response.status_code == 302
    assert response.headers["Location"] == reverse("shell")


def test_logout_rejects_get_requests(
    client: Client,
) -> None:
    response = client.get(reverse("accounts:logout"))

    assert response.status_code == 405


def test_logout_requires_csrf_token() -> None:
    user = User.objects.create_user(
        email="mats@example.com",
        password=_valid_password(),
    )
    csrf_client = Client(enforce_csrf_checks=True)
    csrf_client.force_login(user)

    response = csrf_client.post(reverse("accounts:logout"))

    assert response.status_code == 403
    assert csrf_client.session["_auth_user_id"] == str(user.pk)


def test_shell_shows_authentication_state(
    client: Client,
    tmp_path: Path,
) -> None:
    user = User.objects.create_user(
        email="mats@example.com",
        password=_valid_password(),
    )
    manifest_path = _write_manifest(tmp_path)

    with override_settings(
        VITE_MANIFEST_PATH=manifest_path,
        VITE_STATIC_PREFIX="careerops",
    ):
        anonymous_response = client.get(reverse("shell"))

        client.force_login(user)
        authenticated_response = client.get(reverse("shell"))

    anonymous_html = anonymous_response.content.decode()
    authenticated_html = authenticated_response.content.decode()

    assert "Sign in" in anonymous_html
    assert "Sign out" not in anonymous_html

    assert user.email in authenticated_html
    assert "Sign out" in authenticated_html
    assert 'method="post"' in authenticated_html


def test_production_cookie_policy_is_explicit(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv(
        "DJANGO_SECRET_KEY",
        "production-cookie-policy-test-secret",
    )
    monkeypatch.setenv(
        "DJANGO_ALLOWED_HOSTS",
        "careerops.example",
    )

    from config.settings import production

    production = importlib.reload(production)

    assert production.SESSION_COOKIE_SECURE is True
    assert production.SESSION_COOKIE_HTTPONLY is True
    assert production.SESSION_COOKIE_SAMESITE == "Lax"

    assert production.CSRF_COOKIE_SECURE is True
    assert production.CSRF_COOKIE_HTTPONLY is True
    assert production.CSRF_COOKIE_SAMESITE == "Lax"


@override_settings(
    LOGIN_THROTTLE_FAILURE_LIMIT=3,
    LOGIN_THROTTLE_WINDOW_SECONDS=300,
    LOGIN_THROTTLE_BLOCK_SECONDS=600,
)
def test_repeated_failed_logins_are_throttled(
    client: Client,
    tmp_path: Path,
) -> None:
    user = User.objects.create_user(
        email="mats@example.com",
        password=_valid_password(),
    )
    manifest_path = _write_manifest(tmp_path)

    with override_settings(
        VITE_MANIFEST_PATH=manifest_path,
        VITE_STATIC_PREFIX="careerops",
    ):
        for _attempt in range(3):
            response = client.post(
                reverse("accounts:login"),
                {
                    "username": user.email,
                    "password": "incorrect-password",
                },
            )

            assert response.status_code == 200

        with patch(
            "django.contrib.auth.forms.authenticate",
            side_effect=AssertionError("Blocked login attempted password authentication."),
        ):
            blocked_response = client.post(
                reverse("accounts:login"),
                {
                    "username": user.email,
                    "password": "incorrect-password",
                },
            )

    assert blocked_response.status_code == 200
    assert "_auth_user_id" not in client.session

    form = blocked_response.context["form"]
    non_field_errors = form.non_field_errors().as_data()

    assert len(non_field_errors) == 1
    assert non_field_errors[0].code == "invalid_login"

    state = LoginThrottleState.objects.get()

    assert state.failure_count == 3
    assert state.blocked_until is not None
