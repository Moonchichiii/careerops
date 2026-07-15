from __future__ import annotations

from typing import TYPE_CHECKING

import pytest
from django.db import DatabaseError
from django.urls import reverse

if TYPE_CHECKING:
    from django.test import Client


def test_liveness_returns_ok(client: Client) -> None:
    response = client.get(reverse("platform:liveness"))

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
    assert response.headers["Cache-Control"] == "no-store"


def test_liveness_has_security_headers(client: Client) -> None:
    response = client.get(reverse("platform:liveness"))

    assert response.headers["X-Content-Type-Options"] == "nosniff"
    assert response.headers["Referrer-Policy"] == "no-referrer"
    assert response.headers["Cross-Origin-Opener-Policy"] == "same-origin"

    policy = response.headers["Content-Security-Policy"]
    assert "default-src 'none'" in policy
    assert "base-uri 'none'" in policy
    assert "frame-ancestors 'none'" in policy
    assert "object-src 'none'" in policy
    assert "'unsafe-inline'" not in policy
    assert "'unsafe-eval'" not in policy


@pytest.mark.django_db
def test_readiness_returns_ready(client: Client) -> None:
    response = client.get(reverse("platform:readiness"))

    assert response.status_code == 200
    assert response.json() == {"status": "ready"}
    assert response.headers["Cache-Control"] == "no-store"


def test_readiness_returns_unavailable_when_database_fails(
    client: Client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fail_connection() -> None:
        msg = "database unavailable"
        raise DatabaseError(msg)

    monkeypatch.setattr("apps.platform.views.connection.ensure_connection", fail_connection)

    response = client.get(reverse("platform:readiness"))

    assert response.status_code == 503
    assert response.json() == {"status": "unavailable"}
    assert response.headers["Cache-Control"] == "no-store"
