from __future__ import annotations

import json
from typing import TYPE_CHECKING

from django.contrib.messages import constants as message_constants
from django.contrib.messages.storage.base import Message
from django.template.loader import render_to_string
from django.test import override_settings
from django.urls import reverse

if TYPE_CHECKING:
    from pathlib import Path

    from django.test import Client


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


def test_shell_renders_complete_csp_safe_page(
    client: Client,
    tmp_path: Path,
) -> None:
    manifest_path = _write_manifest(tmp_path)

    with override_settings(
        VITE_MANIFEST_PATH=manifest_path,
        VITE_STATIC_PREFIX="careerops",
    ):
        response = client.get(reverse("shell"))

    html = response.content.decode()
    vary = {value.strip() for value in response.headers["Vary"].split(",")}

    assert response.status_code == 200
    assert response.headers["Cache-Control"] == "no-store"
    assert "HX-Request" in vary

    assert "<!doctype html>" in html.lower()
    assert 'id="shell-status"' in html
    assert 'hx-target="#shell-status"' in html
    assert 'src="/static/careerops/assets/main-test.js"' in html
    assert 'href="/static/careerops/assets/main-test.css"' in html

    assert "<style" not in html
    assert " style=" not in html
    assert "<script>" not in html
    assert "onclick=" not in html

    policy = response.headers["Content-Security-Policy"]
    assert "'unsafe-inline'" not in policy
    assert "'unsafe-eval'" not in policy


def test_shell_returns_only_native_partial_for_htmx(
    client: Client,
    tmp_path: Path,
) -> None:
    manifest_path = _write_manifest(tmp_path)

    with override_settings(
        VITE_MANIFEST_PATH=manifest_path,
        VITE_STATIC_PREFIX="careerops",
    ):
        response = client.get(
            reverse("shell"),
            {"status": "refreshed"},
            headers={"HX-Request": "true"},
        )

    html = response.content.decode()
    vary = {value.strip() for value in response.headers["Vary"].split(",")}

    assert response.status_code == 200
    assert response.headers["Cache-Control"] == "no-store"
    assert "HX-Request" in vary

    assert 'id="shell-status"' in html
    assert "Django returned the native partial." in html
    assert "<!doctype html>" not in html.lower()
    assert "app-masthead" not in html
    assert "<script" not in html
    assert "<style" not in html


def test_shell_preserves_full_page_fallback_without_htmx(
    client: Client,
    tmp_path: Path,
) -> None:
    manifest_path = _write_manifest(tmp_path)

    with override_settings(
        VITE_MANIFEST_PATH=manifest_path,
        VITE_STATIC_PREFIX="careerops",
    ):
        response = client.get(reverse("shell"), {"status": "refreshed"})

    html = response.content.decode()

    assert response.status_code == 200
    assert "<!doctype html>" in html.lower()
    assert "Django returned the native partial." in html
    assert "app-masthead" in html


def test_base_layout_renders_django_messages(
    tmp_path: Path,
) -> None:
    manifest_path = _write_manifest(tmp_path)
    message = Message(
        message_constants.SUCCESS,
        "Foundation ready.",
    )

    with override_settings(
        VITE_MANIFEST_PATH=manifest_path,
        VITE_STATIC_PREFIX="careerops",
    ):
        html = render_to_string(
            "base.html",
            {"messages": [message]},
        )

    assert "Foundation ready." in html
    assert 'data-level="success"' in html
    assert 'aria-label="Notifications"' in html
