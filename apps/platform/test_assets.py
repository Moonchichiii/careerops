from __future__ import annotations

import json
from typing import TYPE_CHECKING

import pytest
from django.template import Context, Template
from django.test import override_settings
from django.urls import reverse

from apps.platform.templatetags.vite import ViteManifestError

if TYPE_CHECKING:
    from pathlib import Path

    from django.test import Client


def _write_manifest(directory: Path) -> Path:
    manifest_path = directory / "manifest.json"
    manifest_path.write_text(
        json.dumps(
            {
                "_shared.js": {
                    "file": "assets/shared-test.js",
                    "css": ["assets/shared-test.css"],
                },
                "src/main.ts": {
                    "file": "assets/main-test.js",
                    "css": ["assets/main-test.css"],
                    "imports": ["_shared.js"],
                    "isEntry": True,
                },
            }
        ),
        encoding="utf-8",
    )
    return manifest_path


def _render_vite_tag() -> str:
    template = Template("{% load vite %}{% vite_assets 'src/main.ts' %}")
    return template.render(Context())


def test_asset_smoke_page_loads_hashed_external_assets(
    client: Client,
    tmp_path: Path,
) -> None:
    manifest_path = _write_manifest(tmp_path)

    with override_settings(
        VITE_MANIFEST_PATH=manifest_path,
        VITE_STATIC_PREFIX="careerops",
    ):
        response = client.get(reverse("asset-smoke"))

    html = response.content.decode()

    assert response.status_code == 200
    assert response.headers["Cache-Control"] == "no-store"

    assert 'rel="modulepreload"' in html
    assert 'href="/static/careerops/assets/shared-test.js"' in html
    assert 'href="/static/careerops/assets/shared-test.css"' in html
    assert 'href="/static/careerops/assets/main-test.css"' in html
    assert 'src="/static/careerops/assets/main-test.js"' in html

    assert "<style" not in html
    assert " style=" not in html
    assert "<script>" not in html
    assert "onclick=" not in html

    policy = response.headers["Content-Security-Policy"]
    assert "'unsafe-inline'" not in policy
    assert "'unsafe-eval'" not in policy


def test_vite_assets_fails_when_manifest_is_missing(tmp_path: Path) -> None:
    with (
        override_settings(
            VITE_MANIFEST_PATH=tmp_path / "missing.json",
            VITE_STATIC_PREFIX="careerops",
        ),
        pytest.raises(ViteManifestError, match="could not be read"),
    ):
        _render_vite_tag()


def test_vite_assets_fails_when_manifest_is_invalid_json(tmp_path: Path) -> None:
    manifest_path = tmp_path / "manifest.json"
    manifest_path.write_text("{invalid", encoding="utf-8")

    with (
        override_settings(
            VITE_MANIFEST_PATH=manifest_path,
            VITE_STATIC_PREFIX="careerops",
        ),
        pytest.raises(ViteManifestError, match="not valid JSON"),
    ):
        _render_vite_tag()


def test_vite_assets_fails_when_entry_is_missing(tmp_path: Path) -> None:
    manifest_path = tmp_path / "manifest.json"
    manifest_path.write_text("{}", encoding="utf-8")

    with (
        override_settings(
            VITE_MANIFEST_PATH=manifest_path,
            VITE_STATIC_PREFIX="careerops",
        ),
        pytest.raises(ViteManifestError, match="was not found"),
    ):
        _render_vite_tag()
