from __future__ import annotations

import json
from pathlib import Path
from typing import TYPE_CHECKING, NotRequired, TypedDict, cast

from django import template
from django.conf import settings
from django.templatetags.static import static
from django.utils.html import format_html, format_html_join

if TYPE_CHECKING:
    from django.utils.safestring import SafeString

register = template.Library()


class ManifestEntry(TypedDict):
    file: str
    css: NotRequired[list[str]]
    imports: NotRequired[list[str]]


type Manifest = dict[str, ManifestEntry]


class ViteManifestError(RuntimeError):
    """Raised when the generated Vite manifest cannot be used safely."""


def _manifest_path() -> Path:
    value: object = getattr(settings, "VITE_MANIFEST_PATH", None)

    if isinstance(value, Path):
        return value

    if isinstance(value, str):
        return Path(value)

    message = "VITE_MANIFEST_PATH must be a filesystem path."
    raise ViteManifestError(message)


def _static_prefix() -> str:
    value: object = getattr(settings, "VITE_STATIC_PREFIX", None)

    if not isinstance(value, str) or not value.strip("/"):
        message = "VITE_STATIC_PREFIX must be a non-empty string."
        raise ViteManifestError(message)

    return value.strip("/")


def _string_list(
    value: object,
    *,
    entry_name: str,
    field_name: str,
) -> list[str]:
    if value is None:
        return []

    if not isinstance(value, list):
        message = f"{entry_name}.{field_name} must be a list."
        raise ViteManifestError(message)

    result: list[str] = []

    for item in value:
        if not isinstance(item, str):
            message = f"{entry_name}.{field_name} must contain only strings."
            raise ViteManifestError(message)

        result.append(item)

    return result


def _load_manifest() -> Manifest:
    path = _manifest_path()

    try:
        content = path.read_text(encoding="utf-8")
    except OSError as exc:
        message = f"Vite manifest could not be read at {path}."
        raise ViteManifestError(message) from exc

    try:
        raw: object = json.loads(content)
    except json.JSONDecodeError as exc:
        message = f"Vite manifest at {path} is not valid JSON."
        raise ViteManifestError(message) from exc

    if not isinstance(raw, dict):
        message = "Vite manifest root must be an object."
        raise ViteManifestError(message)

    manifest: Manifest = {}

    for raw_name, raw_entry in cast("dict[object, object]", raw).items():
        if not isinstance(raw_name, str) or not isinstance(raw_entry, dict):
            message = "Vite manifest entries must map names to objects."
            raise ViteManifestError(message)

        entry_data = cast("dict[object, object]", raw_entry)
        file_name = entry_data.get("file")

        if not isinstance(file_name, str) or not file_name:
            message = f"Vite manifest entry {raw_name} has no valid file."
            raise ViteManifestError(message)

        entry: ManifestEntry = {"file": file_name}

        css = _string_list(
            entry_data.get("css"),
            entry_name=raw_name,
            field_name="css",
        )
        imports = _string_list(
            entry_data.get("imports"),
            entry_name=raw_name,
            field_name="imports",
        )

        if css:
            entry["css"] = css

        if imports:
            entry["imports"] = imports

        manifest[raw_name] = entry

    return manifest


def _ordered_chunks(manifest: Manifest, entry_name: str) -> list[str]:
    ordered: list[str] = []
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(chunk_name: str) -> None:
        if chunk_name in visited:
            return

        if chunk_name in visiting:
            message = f"Vite manifest import cycle detected at {chunk_name}."
            raise ViteManifestError(message)

        entry = manifest.get(chunk_name)

        if entry is None:
            message = f"Vite manifest entry {chunk_name} was not found."
            raise ViteManifestError(message)

        visiting.add(chunk_name)

        for imported_chunk in entry.get("imports", []):
            visit(imported_chunk)

        visiting.remove(chunk_name)
        visited.add(chunk_name)
        ordered.append(chunk_name)

    visit(entry_name)
    return ordered


def _asset_url(asset_path: str) -> str:
    return static(f"{_static_prefix()}/{asset_path}")


@register.simple_tag
def vite_assets(entry_name: str) -> SafeString:
    manifest = _load_manifest()
    chunk_names = _ordered_chunks(manifest, entry_name)
    tags: list[SafeString] = []

    for chunk_name in chunk_names:
        if chunk_name == entry_name:
            continue

        tags.append(
            format_html(
                '<link rel="modulepreload" href="{}">',
                _asset_url(manifest[chunk_name]["file"]),
            )
        )

    emitted_css: set[str] = set()

    for chunk_name in chunk_names:
        for css_file in manifest[chunk_name].get("css", []):
            if css_file in emitted_css:
                continue

            emitted_css.add(css_file)
            tags.append(
                format_html(
                    '<link rel="stylesheet" href="{}">',
                    _asset_url(css_file),
                )
            )

    tags.append(
        format_html(
            '<script type="module" src="{}"></script>',
            _asset_url(manifest[entry_name]["file"]),
        )
    )

    return format_html_join("\n", "{}", ((tag,) for tag in tags))
